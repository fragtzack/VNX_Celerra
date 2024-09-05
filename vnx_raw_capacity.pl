#!/usr/bin/perl
use Net::SMTP;
use File::stat;

my @vnx = ("somnas500spa","ndhnas500spa","sdcuns600spa","kzouns600spa"); 

my $sender = "dl-storagereportsnalerts\@pfizer.com";
my $subject;

my @recipientList = ("michael.shevory\@emc.com");



my  @lines;

my $line;
my $cmd;
my $disk = "";

my $lun;
my $output;

my %capacityList;

my $inputfile = "c:\\scripts\\VNX\\VNX_block_list.txt";

foreach $array (@vnx) 
{ 
    chomp $array;
    print "$array\n";
    print "Gathering data...\n";
    $cmd= "naviseccli -h $array arrayname";
    $output = `$cmd`;
    $output =~ m/Array Name:\s+(\S+)/;
    $arrayName = $1;
    chomp $arrayName;
    
    $cmd= "naviseccli -h $array getagent"; 
    $output = `$cmd`;
    $output =~ m/Serial No:\s+(\S+)/;
    my $serial_number = $1;
    chomp $serial_number; 
    print $serial_number,"\n";
    $capacityList{$serial_number}{array_name} = $arrayName;
    
    $cmd =  "naviseccli  -h $array getdisk -capacity";
    $output = `$cmd`;
    @lines = split('\n',$output);
    
    foreach $line (@lines)
    {
        #print $line,"\n";
        chomp $line;



        if ($line =~m/(^Capacity):\s+(\S+)/)
        {
            $capacityList{$serial_number}{capacity}{Total} += $2;                   
        }
        
    }
    $cmd =  "naviseccli -h $array storagepool -list  | grep \"Pool Name\\\|Raw Capacity (GBs)\\\|Consumed Capacity (GBs)\"";
    print "$cmd\n";
   
    $output = `$cmd`;
    print $output;
    @lines = split('\n',$output);
    my $storagetype = "";
    foreach $line (@lines)
    {
        print $line,"\n";
        if ($line =~ m/(FS_pool_\d+)|(CKPT_pool_\d+)/)
        {
            $storagetype = "NAS";
            
        }
        if ($line =~ m/(BLK_pool_\d+)/)
        {
            $storagetype = "SAN";
        }
        
        if($line =~ m/(Raw) Capacity \(GBs\):\s+(\S+)/ || $line=~ m/(Consumed) Capacity \(GBs\):\s+(\S+)/)
        {   print "$storagetype\n";
            print "$1         $2\n";
            
            $capacityList{$serial_number}{$storagetype}{$1} += $2;
            
        }
        
    }
    print "Inputing data...\n";



}

my $body = &convert_html(\%capacityList);
&send_mail($body);


sub convert_html
{
    my $hash_ref = shift;
    $body .=  "<pre><html><head><title>VNX File Capacity Report</title>";
    $body .=  "</head><body>";
    $body .=  "<table border='1'>";
    $body .=  "<th><font face=\"Tahoma\" size=2>VNX Array</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Serial Number</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>TotalRaw Capacity TB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>NAS Raw Capacity TB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>SAN Raw Capacity TB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Unconfigured Raw Capacity TB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Block pool NAS Consumed Capacity TB</font></th>";
    $body .=  "<th><font face=\"Tahoma\" size=2>Block pool SAN Consumed Capacity TB</font></th>";
    
    
    print "$unconfigured\n";
    foreach $key (sort keys %$hash_ref)
    { 
            $unconfigured = ($hash_ref->{$key}{capacity}{Total}/1024) - ($hash_ref->{$key}{NAS}{Raw} + $hash_ref->{$key}{SAN}{Raw});
            
            $body .= 
            "<tr>
                
                <td><font face=\"Tahoma\" size=2>".$hash_ref->{$key}{array_name}."</font></td>
                <td><font face=\"Tahoma\" size=2>".$key."</font></td>
                <td><font face=\"Tahoma\" size=2>".sprintf("%.2f",$hash_ref->{$key}{capacity}{Total}/(1024*1024))."</font></td>  
                <td><font face=\"Tahoma\" size=2>".sprintf("%.2f",$hash_ref->{$key}{NAS}{Raw}/(1024))."</font></td> 
                <td><font face=\"Tahoma\" size=2>".sprintf("%.2f",$hash_ref->{$key}{SAN}{Raw}/(1024))."</font></td> 
                <td><font face=\"Tahoma\" size=2>".sprintf("%.2f",$unconfigured/(1024))."</font></td> 
                <td><font face=\"Tahoma\" size=2>".sprintf("%.2f",$hash_ref->{$key}{NAS}{Consumed}/(1024))."</font></td> 
                <td><font face=\"Tahoma\" size=2>".sprintf("%.2f",$hash_ref->{$key}{SAN}{Consumed}/(1024))."</font></td>  
            </tr>";
        
    }

    $body .= "</table></body></html>";

}

sub send_mail
{
    $output = shift;
    $subject = "VNX Raw Capacity Report";
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

