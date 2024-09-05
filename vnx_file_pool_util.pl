#!/usr/bin/perl
use Net::SMTP;
use File::stat;
use Time::localtime;
use Net::OpenSSH;

my $user = "nasadmin";
my $password = 'bh0rA$h';
my $ssh;

my @vnx = ("somnas500","ndhnas500","sdcuns600","kzouns600","ndhnas502","ndhnas503","ndhnas504","somnas501","frenas500","edcnas500","edcnas501","rinuns600","bernas500","rrwnas500"); 
#my @vnx = ("somnas500","ndhnas500","sdcuns600","kzouns600","ndhnas502","ndhnas503","ndhnas504","somnas501","frenas500","edcnas500","edcnas501","bernas500"); 
#my @vnx = ("rrwnas500");
#my @vnx = ("rdpemanas01","somnas500");
my $sender = "dl-storagereportsnalerts\@pfizer.com";
my $subject;
#my @recipientList = ("StorMSPfizerCapacity\@emc.com,PfizerAHSStorageGlobal\@emc.com");
#my @recipientList = ("michael.denney\@pfizer.com");
my @recipientList = ("johntrey.nix\@pfizer.com");


my @array;   
my %utildetails;

foreach $v (@vnx) 
{
    #print "$v\n";
    &get_pool_details($v);
    &get_fs_details($v);
    &get_ckpt_details($v);
    
} 
&convert_html(\%utildetails);  
&send_mail($body);

sub get_pool_details
{
    my $host = shift;
    my $pool;
    print("$host\n");
    $ssh = Net::OpenSSH->new(host=>$host, user=>$user, password=>$password, master_opts => [-o => "StrictHostKeyChecking=no"]);
    $poollist = $ssh->capture("export NAS_DB=/nas;/nas/bin/nas_pool -l");
    @poollist = split('\n',$poollist);
    foreach $poolline (@poollist)
    {
        if ($poolline =~ m/\d*\s+\w\s+\d\s+(\S+)/)
        {
            $pool = $1;
            my $cmd ="export PATH=$PATH:/usr/local/bin:/bin:/usr/bin:/nas/sbin:/nas/bin;export NAS_DB=/nas;/usr/bin/perl /nas/log/mck/nas_pool_mxsz3.pl $pool"; 
            my $pool_stats = $ssh->capture($cmd);
            #print $pool_stats;
            @lines = split('\n',$pool_stats);
            
            foreach $line (@lines) 
	    {   
                $line =~ m/(\S+)\s+\=\s+(\S+)/;
                $type = $1;
                $value = $2;
                if ($type =~ m/used_mb|avail_mb|total_mb|potential_mb|VPmxsz_mb/)
                {
                    $value = sprintf("%.2f",$value/(1024));
                }
                #print "$type     $value\n";
  		$utildetails{$host}{$pool}{$type} = $value; 
                        
            }
                    
        }
      
    }
}

sub get_fs_details
{
    $host = shift;
    $fslist = $ssh->capture('export NAS_DB=/nas;/nas/bin/nas_fs -query:IsRoot==False:TypeNumeric==1 -format:\'%s,%s\n\' -fields:Name,StoragePoolName');
    @fslist = split('\n',$fslist);
    $fssize = $ssh->capture('export NAS_DB=/nas;/nas/bin/nas_fs -info -size -all | grep "name\|^size" | sed \'N;G;s/\n/\t/g\' | grep -v "name      = ckpt\|name      = root\|savpool"|awk \'{print $3"\t"$14}\'');
    #print "$fssize\n";
    my @fssize = split('\n',$fssize);
    foreach $fsline (@fslist)
    {
        if ($fsline =~ m/(\S+)\,(\S+)/)
        {

            $fs =$1;
            $pool = $2;
            @fsdetail = grep (/$fs/, @fssize);
            $fsstats = shift @fsdetail;
            
            $fsstats =~ m/\S+\s+(\d+)/;
            $uc = $1;
            $utildetails{$host}{$pool}{uc} =0 if !$utildetails{$host}{$pool}{uc};
            $utildetails{$host}{$pool}{uc} += $uc;
            #print "$fs,$utildetails{$host}{$pool}{uc}\n";

        }
    }
}

sub get_ckpt_details
{
    $host = shift;
    $ckptlist = $ssh->capture('export NAS_DB=/nas;/nas/bin/nas_fs -query:IsRoot==False:TypeNumeric==1 -format:\'%q\' -fields:Checkpoints -query:* -format:\'%s,%s,%s,%s,%s,%s\n\' -fields:BackupOf,Name,CkptSavVolUsedMB,Size,PctUsed,StoragePoolName');
    @ckptlist = split('\n',$ckptlist);
    foreach $ckptline (@ckptlist)
    {
        if ($ckptline =~ m/(\S+)\,(\S+),(\S+)\,(\S+),(\S+)\,(\S+)/)
        {

            $ckpt =$2;
            $uc = $3;
            $pool = $6;
            $utildetails{$host}{$pool}{uc} =0 if !$utildetails{$host}{$pool}{uc};
            $utildetails{$host}{$pool}{uc} += $uc;
            #print "$ckpt,$utildetails{$host}{$pool}{uc}\n";

        }
    }
}

sub convert_html
{
    print("\n\nEntering convert_html\n\n");
    my $hash_ref = shift;
    $body .=  "<pre><html><head><title>VNX File Capacity Report</title>";
    $body .=  "</head><body>";
    $body .=  "<table border='1'>";
    $body .=  "<th><font face=\"Tahoma\" size=2>VNX Array</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Pool Name</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Pool ID</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Allocated GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Used GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Avail GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Total GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Total Max Size GB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Subcription Rate</font></th>";
    
   
    foreach $key (sort keys %$hash_ref)
    {
       
        
        foreach $key2 (keys %{$hash_ref->{$key}})
        {  

            $uc = sprintf("%.2f",$hash_ref->{$key}{$key2}{uc}/(1024));
            $total = $hash_ref->{$key}{$key2}{total_mb} + $hash_ref->{$key}{$key2}{potential_mb};  
           #$uc = $hash_ref->{$key}{$key2}{uc};
            $avail = $hash_ref->{$key}{$key2}{avail_mb} + $hash_ref->{$key}{$key2}{potential_mb};
            $sub = sprintf("%.2f",($hash_ref->{$key}{$key2}{VPmxsz_mb}/$total)*100); 
            $body .= 
            "<tr>
                <td><font face=\"Tahoma\" size=2>".$key."</font></td>
                <td><font face=\"Tahoma\" size=2>".$key2."</font></td>
                <td><font face=\"Tahoma\" size=2>".$hash_ref->{$key}{$key2}{id}."</font></td>
                <td><font face=\"Tahoma\" size=2>".$hash_ref->{$key}{$key2}{used_mb}."</font></td>
                <td><font face=\"Tahoma\" size=2>".$uc."</font></td>
                <td><font face=\"Tahoma\" size=2>".$avail."</font></td>
                <td><font face=\"Tahoma\" size=2>".$total."</font></td>
                <td><font face=\"Tahoma\" size=2>".$hash_ref->{$key}{$key2}{VPmxsz_mb}."</font></td>
                <td><font face=\"Tahoma\" size=2>".$sub."%</font></td>                
            </tr>";
        }
        
    }

    $body .= "</table></body></html>";
}



sub send_mail
{
    $output = shift;
    $subject = "VNX File Capacity Report";
    $smtp = Net::SMTP->new("mailhub.pfizer.com");  
    
    $realbody .= $output;
    $smtp->mail($sender);
    $smtp->recipient(@recipientList);
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
