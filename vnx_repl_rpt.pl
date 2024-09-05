#!/usr/bin/perl -w
###########################################################################
## vnx_repl_rpt.pl
my $VERSION=1.22;
## Written by Michael Denney (michael.s.denney@gmail.com)
##
## Report on VNX replications, raise issue if lag time > specified limit
###########################################################################
##HISTORY
##0.1  Initial
##0.2  minor formats
##1.1  vnx.conf
##1.11 -m fix
##1.13 $com->chk_err
##1.14 push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
##1.15 fixed issue with replications that do not have an initial "lastsynctime"
##1.16 fixed issue with lag_check sub never flagging
##1.21 Add interconenct names to report
##1.22 Fix to no replication sessions
###########################################################################
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX;
use Time::Local;
use File::Basename;
use File::Copy;
use Data::Dumper;
use Getopt::Long;
use Date::Parse;
use Rpt;
use Common;
use NAS::VNX;
###########################################################################
## global declarations
###########################################################################
use vars qw($VERSION $mail_to @email_rpt @email_rpt_headers @error_rpt );
use vars qw(@email_rpt_headers $hosts $fresh);
use vars qw($verbose $debug $excel_file);
use vars qw($vnx); 
##$vnx= object for each vnx, needs to be undef at start of each big loop
use vars qw(@repl_rpt @repl_rpt_headers); 
use vars qw(@lag_rpt @lag_rpt_headers); 
use vars qw(@not_ok_rpt @not_ok_rpt_headers); 
use vars qw(@exclude_rpt @exclude_rpt_headers); 

use subs qw(prep_email prep_excel send_email);
use subs qw(get_repl lag_check notok_check);
use subs qw(connects);
###########################################################################
#process command line
###########################################################################
exit 1 unless GetOptions(
          'v' => \$verbose,
          'f|fresh' => \$fresh,
          'm|mail=s' => \$mail_to,
          'h|host=s' => \@$hosts,
          'd' => \$debug
);
###########################################################################
## load $config_file
###########################################################################
chdir ($FindBin::Bin);
my $com=Common->new;
$com->log_file("$FindBin::Bin/../var/log/$Common::shortname.log");
$com->verbose(1) if ($verbose);
my $config_file="$FindBin::Bin/../etc/$Common::shortname.conf";
my %configs=read_config($config_file);
$configs{shared_conf}= $configs{shared_conf} or die "shared_conf required in $config_file $!";
my %shared_confs=read_config($configs{shared_conf});
my %vnx_confs=read_config('../etc/vnx.conf');
%shared_confs=over_rides(\%configs,\%shared_confs);
%shared_confs=over_rides(\%vnx_confs,\%shared_confs);
$shared_confs{email_to}=$mail_to if ($mail_to);
############################################################################
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$mon++;
my $YEAR=substr($year,1);
my $DATE=sprintf("%02d%02d%02d",$mon,$mday,$YEAR);
$hosts=hosts($shared_confs{hosts_file}) unless (@$hosts);
#@hosts=('ppkvfs100');
@lag_rpt_headers=qw(Source Destination Repl_Name Lag Source_Status Network_Status);
@not_ok_rpt_headers=qw(Source Destination Repl_Name Source_Status Dest_Status  Network_Status);
@exclude_rpt_headers=qw(Source Destination Repl_Name Flag_Reason);
my ($excludes,$excludes1,$excludes2)=load_manage_exclusions("$FindBin::Bin/../etc/$Common::shortname.conf");
#########################################################################
## MAIN
#########################################################################
foreach my $curr_host (sort @$hosts){
   $com->add_to_log("INFO ".curr_date_time." host=>$curr_host");
   $shared_confs{host}=$curr_host;
   undef $vnx;
   $vnx=VNX->new(\%shared_confs);
   $vnx->verbose(1) if $verbose;
   $vnx->fresh_val(0) if $fresh;
   next if $com->chk_err($vnx,$vnx->chk_host_connect);
   get_repl;
}
push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
my $rpt_object=Rpt->new(\%shared_confs);
my $bdir=$rpt_object->daily_rpt_dir;
$rpt_object->daily_rpt_dir("$bdir/$Common::shortname");

prep_excel;
my $html_file="../tmp/$mday$Common::num2mon{$mon}20$YEAR.html";
my $excel_target="$mday$Common::num2mon{$mon}20$YEAR-$hour-$min".basename($excel_file);
prep_email if $rpt_object->email_to;
open HTML,">$html_file";
print HTML $rpt_object->email;
close HTML;
$rpt_object->cp_to_daily($html_file);
$rpt_object->cp_to_daily($excel_file,$excel_target);
send_email;
unlink($excel_file) if (-f $excel_file);
unlink($html_file) if (-f $html_file);
exit; 
###############################################################################
sub connects{
###############################################################################
   #returns the destination hostname from nas_cel given a remoteSystem id
  my $inter=shift;
  my $cel=$vnx->q_nas_cel;
  return undef if ($com->chk_err($vnx,'fake value'));
  return lc $$cel{$inter}{Name}||'-';

}
###############################################################################
sub notok_check{
###############################################################################
   my $repl=shift;
   unless (($$repl{sourceStatus} eq 'OK') and
          ($$repl{destinationStatus} eq 'OK') and
          ($$repl{networkStatus} eq 'OK')){
          #next if check_exclude($vnx->host,$sourceFS,$excludes);
         $com->add_to_log("WARN ".curr_date_time." ".$vnx->host." ".$$repl{name}." not OK status ");
         if (check_exclude($vnx->host,$$repl{name},$excludes) ||
          check_exclude($vnx->host,$$repl{name},$excludes1)){
          $com->add_to_log("WARN ".curr_date_time." ".$vnx->host." excluding $$repl{name}");
          push @exclude_rpt,[
                          $vnx->host,
                          connects($$repl{remoteSystem}),
                          $$repl{name}||' ',
                          'NotOk'
                           ];
          return undef;
      }

         push @not_ok_rpt,[
                          $vnx->host,
                          connects($$repl{remoteSystem}),
                          $$repl{name}||' ',
                          $$repl{sourceStatus},
                          $$repl{destinationStatus},
                          $$repl{networkStatus}
                          ];
   }
}
###############################################################################
sub lag_check{
###############################################################################
   my $repl=shift;
   my $timestamp=shift;
   #print Dumper($repl);
   return undef unless ($$repl{lastSyncTime});
   #return undef unless ($$repl{id} eq '21387_APM00124909351_2007_1350_APM00134940297_2007');
   #print $$repl{id}." last sync ".$$repl{lastSyncTime}."\n";
   #print $$repl{name}."\n";
   #print "timestamp $timestamp\n";
   #print Dumper ($repl);
   my $dm=$$repl{sourceMover};
   #get timezone for datamover
   my $tz=${$vnx->q_server_date}{$dm}{tz};
   #say "TZ=>$tz";
   my $sync_epoc=str2time($$repl{lastSyncTime},$tz);
   #print "sync_epoc $sync_epoc\n";
   my @ary=stat($vnx->host_dir.'/nas_replicate.txt');
   my $lag=$timestamp-$sync_epoc;
   my $lag_second=(($lag%3600)%60);
   my $lag_minute=((($lag-$lag_second)%3600)/60);
   my $lag_hour=(($lag-$lag_second-($lag_minute*60))/3600);
   my $lagminutes=($lag-$lag_second)/60;
   $lag="$lag_hour:$lag_minute:$lag_second";
   #print "lag => $lag\n";
   
   if (($lagminutes > $configs{lag_threshold})||($lag eq "-"))  {
      print $vnx->host." ".$$repl{name}." LAG $lag greater then threshold ".$configs{lag_threshold}."\n" if $verbose;
      $com->add_to_log("WARN ".curr_date_time." ".$vnx->host." ".$$repl{name}." LAG $lag greater then threshold ".$configs{lag_threshold});
      if (check_exclude($vnx->host,$$repl{name},$excludes) || 
          check_exclude($vnx->host,$$repl{name},$excludes2)){
          $com->add_to_log("WARN ".curr_date_time." ".$vnx->host." excluding $$repl{name}");
          push @exclude_rpt,[
                        $vnx->host, 
                        connects($$repl{remoteSystem}),
                        $$repl{name},
                        'lag',
                        ];
          return $lag;
      }
      push @lag_rpt,[
                    $vnx->host, 
                    connects($$repl{remoteSystem}),
                    $$repl{name},
                    $lag,
                    $$repl{sourceStatus},
                    $$repl{networkStatus}
                    ];
   }
   return ($lag);
}
###############################################################################
sub get_repl{
###############################################################################
  ##get replications and report into @replicate_rpt
  ##First get interconencts
  my $inter=$vnx->q_nas_cel_interconnect;
  ($com->chk_err($vnx,'fake value'));
  my $repl=$vnx->q_nas_replicate;
  return undef if ($com->chk_err($vnx,'fake value'));
  return undef unless ($repl and %$repl);
  my $nas_cel=$vnx->q_nas_cel;
  my @ary=stat($vnx->host_dir.'/nas_replicate.txt');
  my $timestamp=$ary[9];
  #print "time stamp $timestamp\n";
  my $collect_time=strftime("%m/%d/%Y %H:%M:%S",localtime $timestamp);
  #print "collect time $collect_time\n";
  foreach (keys %$repl){
    next unless ($$repl{$_}{localRole}=~/source/);
    notok_check($$repl{$_});
    #notok_check($$repl{$_}) unless ($$repl{$_}{localRole}=~/source/);
    my $lag=lag_check($$repl{$_},$timestamp);
    my $fs_id= $$repl{$_}{sourceFilesystem};
    my $fs_name=' ';
    if ($fs_id){
      $fs_name=${$vnx->q_nas_fs_id}{$fs_id}{Name}||' ';
    }
    my $iid=$$repl{$_}{dartInterconnect}||0;
    my $iname=$$inter{$iid}{name}||' ';
    push @repl_rpt,[
           $vnx->host,
           $$repl{$_}{name}||' ',
           $collect_time,
           $lag,
           $$repl{$_}{id}||' ',
           $$repl{$_}{sourceStatus}||' ',
           $$repl{$_}{networkStatus}||' ',
           $$repl{$_}{destinationStatus}||' ',
           $$repl{$_}{lastSyncTime}||' ',
           $$repl{$_}{object}||' ',
           connects($$repl{$_}{remoteSystem}),
           $iname,
           $$repl{$_}{dartInterconnect}||' ',
           $$repl{$_}{peerInterconnect}||' ',
           $$repl{$_}{localRole}||' ',
           $$repl{$_}{sourceFilesystem}||' ',
           $fs_name,
           $$repl{$_}{sourceVdm}||' ',
           $$repl{$_}{sourceMover}||' ',
           $$repl{$_}{sourceInterface}||' ',
           $$repl{$_}{sourceControlPort}||'0',
           $$repl{$_}{curTransferSourceDataPort}||'0',
           $$repl{$_}{destinationFilesystem}||' ',
           $$repl{$_}{destinationVdm}||' ',
           $$repl{$_}{destinationMover}||' ',
           $$repl{$_}{destinationInterface}||' ',
           $$repl{$_}{destinationControlPort}||'0',
           $$repl{$_}{destinationDataPort}||' ',
           $$repl{$_}{maxTimeOutOfSync}||' ',
           $$repl{$_}{curTransferTotalSizeKB}||' ',
           $$repl{$_}{curTransferRemainSizeKB}||' ',
           $$repl{$_}{curTransferEstEndTime}||' ',
           $$repl{$_}{curTransferIsFullCopy}||' ',
           $$repl{$_}{curTransferRateKB}||' ',
           $$repl{$_}{curReadRateKB}||' ',
           $$repl{$_}{curWriteRateKB}||' ',
           $$repl{$_}{prevTransferRateKB}||' ',
           $$repl{$_}{prevReadRateKB}||' ',
           $$repl{$_}{prevWriteRateKB}||' ',
           $$repl{$_}{avgTransferRateKB}||' ',
           $$repl{$_}{avgReadRateKB}||' ',
           $$repl{$_}{avgWriteRateKB}||' ',
           $$repl{$_}{isCopy}||' ',
           $$repl{$_}{internalSnaps}||' ',
           $$repl{$_}{latestSrcSnap}||' ',
           $$repl{$_}{curTransferSnap}||' ',
           $$repl{$_}{latestDstSnap}||' ',
           $$repl{$_}{waitingSnaps}||' ',
           $$repl{$_}{sourceTarget}||' ',
           $$repl{$_}{destinationTarget}||' ',
           $$repl{$_}{appData}||' ',
           $$repl{$_}{sourceLun}||' ',
           $$repl{$_}{destinationLun}||' ',
    ];
  }#foreach (keys %$repl){
  @repl_rpt_headers=('VNX ','session name ','collect time','lag time','session id','sourceStatus','networkStatus','destinationStatus','lastSyncTime ','object ','remoteSystem','InterconnectName','dartInterconnect','peerInterconnect','localRole ','sourceFilesystem ID','sourceFilesystem','sourceVdm','sourceMover','sourceInterface','sourceControlPort','curTransferSourceDataPort','destinationFilesystem ','destinationVdm','destinationMover','destinationInterface','destinationControlPort','destinationDataPort','maxTimeOutOfSync','curTransferTotalSizeKB','curTransferRemainSizeKB','curTransferEstEndTime','curTransferIsFullCopy','curTransferRateKB','curReadRateKB','curWriteRateKB','prevTransferRateKB','prevReadRateKB','prevWriteRateKB','avgTransferRateKB','avgReadRateKB','avgWriteRateKB','isCopy ','internalSnaps','latestSrcSnap','curTransferSnap','latestDstSnap','waitingSnaps','sourceTarget','destinationTarget','appData ','sourceLun ','destinationLun' );
}
###############################################################################
sub prep_email{
###############################################################################
   my (@eheaders,@status_rpt,$status);
   #push @eheaders,"<a href=\"\\\\ndhnas500vfs02\\nas_admin\\Scripts\\nas\\var\\Daily_Reports\\$Common::shortname\\$excel_target\">Spreadsheet Rpt</a>";
   push @status_rpt,"<a href=\"$shared_confs{cifs_daily_rpt_dir}\\$Common::shortname\\$excel_target\">NAS share spreadsheet Rpt</a>";
   if ((@lag_rpt) || (@not_ok_rpt)){
     $status='Red';
     push @status_rpt,"Issue detected with replication session(s).";
   }else{
     $status='Green';
     push @status_rpt,'All Replications sessions OK status.';
     push @status_rpt,"All Replications sessions under $configs{lag_threshold} minute threshold.";
   }
   $rpt_object->MakeEmailStatusHeaders($status,\@status_rpt);
   $rpt_object->MakeEmailBodyHeaders('','',\@eheaders) if ($status eq 'Green');
   if (@lag_rpt){
     $rpt_object->MakeEmailBodyHeaders('',"<font color=\"990000\">Sessions where lag above $configs{lag_threshold} minute threshold:</font>",\@eheaders);
     $rpt_object->MakeEmailBody(\@lag_rpt_headers,\@lag_rpt);
     undef @status_rpt;
   }
   if (@not_ok_rpt){
     $rpt_object->MakeEmailBodyHeaders('','<font color="990000">Sessions where status not OK:</font>',\@eheaders);
     $rpt_object->MakeEmailBody(\@not_ok_rpt_headers,\@not_ok_rpt);
     undef @status_rpt;
   }
   #$rpt_object->MakeEmailBodyHeaders('','',\@eheaders);
   $rpt_object->MakeEmailBody(\@email_rpt_headers,\@email_rpt) if (@email_rpt_headers and @email_rpt);
   if (@error_rpt){
      my @title; my @err_headers=('VNX','Error Message');
      push @title,"Errors detected during report:";
      $rpt_object->MakeEmailStatusHeaders('Red',\@title);
      $rpt_object->MakeEmailBody(\@err_headers,\@error_rpt);
      $rpt_object->email("<BR>&nbsp;<BR>\n");
   }
   my @footers;
   my $conf_file="$shared_confs{cifs_conf_dir}\\$Common::shortname.conf";
   my $doc_file="$shared_confs{cifs_conf_dir}\\..\\doc\\$Common::shortname.docx";
   push @footers,"<a href=\"$doc_file\">Report Documentation</a>";
   push @footers,"<a href=\"$conf_file\">Report Config File</a>";
   push @footers,"$Common::basename ver $VERSION";
   $rpt_object->MakeEmailFooter(\@footers);
   return 1;

}
###########################################################################
sub prep_excel{
###########################################################################
   $excel_file="../tmp//$Common::shortname.xlsx";
   $com->add_to_log("INFO making excel $excel_file");
   $rpt_object->excel_file($excel_file);
   $rpt_object->excel_tabs('Replications Rpt',\@repl_rpt_headers,\@repl_rpt,2) if @repl_rpt;
   $rpt_object->excel_tabs('Lag Rpt',\@lag_rpt_headers,\@lag_rpt,2) if @lag_rpt;
   $rpt_object->excel_tabs('Not Ok Rpt',\@not_ok_rpt_headers,\@not_ok_rpt,2) if @not_ok_rpt;
   $rpt_object->excel_tabs('Exclude Rpt',\@exclude_rpt_headers,\@exclude_rpt,2) if @exclude_rpt;
   $rpt_object->write_excel_tabs if ($rpt_object->excel_tabs);
}
###########################################################################
sub send_email{
###########################################################################
   #print Dumper(@email_rpt_headers);exit;
   $rpt_object->email_subject("$configs{email_subject} ".curr_date_time) if ($configs{email_subject});
   $com->add_to_log("INFO sending email to ".$rpt_object->email_to);
   $rpt_object->email_attachment($excel_file) if (-f $excel_file);
   $rpt_object->SendEmail;# unless ($mail_to eq 'none')
}
