#!/usr/bin/perl
use Net::SMTP;
use File::stat;
use Time::localtime;
use Net::OpenSSH;

my $user = "nasadmin";
my $password = 'bh0rA$h';
my $ssh;


my @vnx = ("somnas500","ndhnas500","sdcuns600","kzouns600","ndhnas502","ndhnas503","ndhnas504","somnas501","frenas500","edcnas500","edcnas501","rinuns600","bernas500","rrwnas500");
#my @vnx = ("rdpemanas01","somnas500");
my $sender = "dl-storagereportsnalerts\@pfizer.com";
my @recipientList_fs = ("StorMSPfizerCapacity@emc.com,michael.denney@pfizer.com,michael.denney@emc.com,Kalpana.Raghupatruni@emc.com,PfizerAHSStorageGlobal@emc.com");
my @recipientList_dm = ("PfizerAHSStorageGlobal\@emc.com");
#my @recipientList_fs = ("michael.denney\@pfizer.com");
#my @recipientList_dm = ("michael.denney\@pfizer.com");



my $body = "";
foreach $host (@vnx)
{
    #print "$host\n";
    $ssh = Net::OpenSSH->new(host=>$host, user=>$user, password=>$password, master_opts => [-o => "StrictHostKeyChecking=no"]);
    my $test = $ssh->capture("export NAS_DB=/nas;/nas/bin/nas_server -l");
    #print "$test\n";

    my $quota_ref = &get_quota_details();
    my ($fs_ref,$dm_ref) = &get_fs_details($quota_ref);
    $fs_ref = &get_security_style($fs_ref);
    
    &convert_html($fs_ref);  
    &send_mail($body,$host,"VNX $host Filesystem Report",\@recipientList_fs);
    $body = "";
    &convert_html_dm($dm_ref);
    &send_mail($body,$host,"VNX $host Datamover Report",\@recipientList_dm); 
    undef %fsdetails;
    undef %quotadetails;
    undef %dmdetails;
} 

sub get_quota_details
{
    my %quotadetails;
    $quotalist = $ssh->capture('export NAS_DB=/nas;/nas/bin/nas_fs -query:*  -fields:TreeQuotas -format:"%q" -query:* -fields:filesystem,path,BlockUsage,BlockHardLimit -format:"%s %-30s %-15d%-10d\n"');
    @quotalist = split('\n',$quotalist);
    foreach $quotaline (@quotalist)
    {
        #print "$quotaline\n";
        if ($quotaline =~ m/(\S+)\s+\S+\s+(\S+)\s+(\S+)/)
        {
             $fs = $1;
             $used = $2;
             $hard =$3;

             $quotadetails{$fs}{hard} =0 if !$quotadetails{$fs}{hard};
             $quotadetails{$fs}{used} =0 if !$quotadetails{$fs}{used};
  	     $quotadetails{$fs}{used} += $used; 
  	     $quotadetails{$fs}{hard} += $hard;
        }    
    }

    return \%quotadetails; 
}

sub get_fs_details
{
    my %fsdetails;
    my $quotadetails = shift;
    $fslist = $ssh->capture('export NAS_DB=/nas;/nas/bin/nas_fs -query:IsRoot==False:TypeNumeric==1 -format:\'%L,%L,%s,%s,%s\n\' -fields:RWservers,rwvdms,name,Size,MaxSize');
    @fslist = split('\n',$fslist);
    foreach $fsline (@fslist)
    {
        #print "$fsline\n"; 
        if ($fsline =~ m/(\S*)\,(\S*)\,(\S+)\,(\S+)\,(\S+)/)
        {
            $dm = $1;
            $vdm = $2;
            $fs =$3;
            $size = $4;
            $msize = $5;
            $fsstats = $ssh->capture("export NAS_DB=/nas;/nas/bin/nas_fs -size $fs");
            #print "$fsstats\n";
            $fsstats =~ m/\S+\s\=\s(\d+)\s\S+\s\=\s(\d+)\s\S+\s\=\s(\d+)/;
            $fc = $2;
            $uc = $3;
            #print $fs,"\n";

  	    $fsdetails{$fs}{dm} = $dm;                           
  	    $fsdetails{$fs}{vdm} = $vdm;
  	    $fsdetails{$fs}{used} = $uc;
  	    $fsdetails{$fs}{free} = $fc;
  	    $fsdetails{$fs}{size} = $size;
  	    $fsdetails{$fs}{maxsize} = $msize;
  	    $fsdetails{$fs}{sumofhard} = $quotadetails->{$fs}{hard};
  	    $fsdetails{$fs}{quotaused} = $quotadetails->{$fs}{used};
            $fsdetails{$fs}{sumofhard} += 2097152000 if ($fs =~ m/sdc600v01wti011/);
            $dmdetails{$dm}{$vdm}{size} +=$size;
            $dmdetails{$dm}{$vdm}{maxsize} += $msize;
        }
    }
   return \%fsdetails,\%dmdetails;
}

sub get_security_style()
{
    my $fsdetails = shift;
    $accesspolicy = $ssh->capture("export NAS_DB=/nas;/nas/bin/server_mount ALL | grep -v \"root\\|ckpt\\|ro\"");
    @accesslist = split('\n',$accesspolicy);
    foreach $accessline (@accesslist)
    {
        if ($accessline  =~ m/\/(\S+)\s\S+accesspolicy=(\w+)\S+(\w\wlock)/ || $accessline =~ m/\/(\S+)\s\S+accesspolicy=(\w+)/)
        {
             $fs = $1;
             $ac = $2;
             $lock = $3;
             $fsdetails->{$fs}{ac} =$ac;
             $fsdetails->{$fs}{lck} =$lock;  
        }
    }
   return $fsdetails; 
    
}
sub convert_html
{
    my $hash_ref = shift;
    $body = "";
    $body .=  "<pre><html><head><title>VNX File Capacity Report</title>";
    $body .=  "</head><body>";
    $body .=  "<table border='1'>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Data Mover</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Virtual Data Mover</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>File System</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Access Policy</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Locking Policy</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Used GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Total GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Total Max Size GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Sum of Hard Quotas GB</font></th>";
    
   
    foreach $key (sort keys %$hash_ref)
    {
          
        $dm = $hash_ref->{$key}{dm};
        $vdm = $hash_ref->{$key}{vdm};
        $used = sprintf("%.0f",($hash_ref->{$key}{used})/(1024));
        $free = sprintf("%.0f",$hash_ref->{$key}{free}/(1024));
        $size = sprintf("%.0f",$hash_ref->{$key}{size}/(1024));
        $maxsize = sprintf("%.0f",$hash_ref->{$key}{maxsize}/(1024));
        $sumofhard = sprintf("%.0f",$hash_ref->{$key}{sumofhard}/(1024*1024));
        $quotaused = sprintf("%.0f",$hash_ref->{$key}{quotaused}/(1024*1024)); 
        $access = $hash_ref->{$key}{ac};
        $lock = $hash_ref->{$key}{lck};   
        $body .= 
            "<tr>
                <td><font face=\"Tahoma\" size=2>".$dm."</font></td>
                <td><font face=\"Tahoma\" size=2>".$vdm."</font></td>
                <td><font face=\"Tahoma\" size=2>".$key."</font></td>
                <td><font face=\"Tahoma\" size=2>".$access."</font></td>
                <td><font face=\"Tahoma\" size=2>".$lock."</font></td>
                <td><font face=\"Tahoma\" size=2>".$used."</font></td>
                <td><font face=\"Tahoma\" size=2>".$size."</font></td>
                <td><font face=\"Tahoma\" size=2>".$maxsize."</font></td>                
                <td><font face=\"Tahoma\" size=2>".$sumofhard."</font></td> 
            </tr>";
        
        
    }

    $body .= "</table></body></html>";

}


sub send_mail
{
    $output = shift;
    $host = shift;
    $subject = shift;
    $recipientList = shift;
    $smtp = Net::SMTP->new("mailhub.pfizer.com");  
    my $realbody = $output;
    $smtp->mail($sender);
    $smtp->recipient(@$recipientList);
    $smtp->data();
    $smtp->datasend("MIME-Version: 1.0\n");
    $smtp->datasend("Content-Type: text/html; charset=us-ascii\n");
    $smtp->datasend("To: @recipientList\nFrom: $sender\nSubject:$subject\n\n");
    $smtp->datasend("\n");
    $smtp->datasend("\n");
    $smtp->datasend($realbody);
    $smtp->dataend;
    $smtp->quit;
    
    $body = "";  
}

sub convert_html_dm
{
    my $hash_ref = shift;
    $body = "";
    $body .=  "<pre><html><head><title>VNX File Capacity Report</title>";
    $body .=  "</head><body>";
    $body .=  "<table border='1'>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Data Mover</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Virtual Data Mover</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Total GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Total Max Size GB</font></th>";


    foreach $key (sort keys %$hash_ref)
    {
        foreach $key2 (keys %{$hash_ref->{$key}})
        {  

            $body .= 
            "<tr>
                <td><font face=\"Tahoma\" size=2>".$key."</font></td>
                <td><font face=\"Tahoma\" size=2>".$key2."</font></td>
                <td><font face=\"Tahoma\" size=2>".sprintf("%.0f",($hash_ref->{$key}{$key2}{size}/1024))."</font></td>
                <td><font face=\"Tahoma\" size=2>".sprintf("%.0f",($hash_ref->{$key}{$key2}{maxsize}/1024))."</font></td>
            </tr>";
        }


    }

    $body .= "</table></body></html>";

}


