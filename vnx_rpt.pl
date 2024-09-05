#!/usr/bin/perl -w
###################################################################################
## hw_rpt.pl
my $VERSION=3.10;
## Author: (michael.s.denney@gmail.com)
##
## Report on VNX inventory
################################################################################
##HISTORY
##0.09 Fix write to Daily_Reports, create csv files also
##0.11 Fixes to creating csv files
##0.12 Released for use, added space to file displays
##0.13 Email subject moved to script conf file
##0.15 CSV files displayed as href in email output
##0.17 added silent option to run_plink
##0.20 uses $rpt_object->MakeEmailFooter
##0.21 removed use NAS::Celerra
##0.23 fixed run_remote_cmd utilization for ssh2
##0.25 id=1 instead of server_2
##0.27 added cifs and nfs servers, added using collect files instead of ssh
##0.29 parse_nas_fs
##0.31 parse_nas_pool
##0.33 parse_server_ftp 
##0.35 parse_iscsi_lun
##0.37 VNX-Block serial now comes from navicli -> clar_serial sub
##0.39 linux ability
##0.40 minor server_export fix (not catching name=)
##1.01 rw_exports_view
##2.03 new structure using NAS::VNX
##2.04 error checking  and error reporting
##2.05 nas_pools_rpt
##2.07 fixes to rw_exports_view
##2.09 @replicate_rpt
##2.11 savvol space added to fs_rpt
##2.14 ckpt_rpt
##2.15 no text unless verbose or error
##2.25 prep_tree_quota_rpt
##2.27 fix to MaxSize on FileSystems exel tab showing 16TB for thick provisions
##2.29 usermapper_users and usermapper_groups
##2.30 checkpoint time stamps converted from epoch to human readable
##2.32 Tree quota info added to rw exports view
##2.33 Minor formats
##2.34 new $vnx->q_nas_fs
##2.40 prep_virus_rpt sub
##2.41 checkers_rpt
##2.51 vnx.conf
##2.52 fix to -m
##2.60 prep_ckpt_schedule
##2.61 push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
##2.71 prep_param_rpt
##2.75 prep_dm_rpt
##2.89 max_size_reached column added to filesystems and max size column moved next o vol total size
##2.91 fix to prep_tree_quota_rpt to properly report on DefaultBlockGracePeriod
##         of BlockGracePeriod not set
##2.93 fix to q_server_cifs to account for multiple cifs server per dm/vdm
##2.94 added inodes to file system report
##2.95 Change r/w exports view tab to exports tab view
##3.00 disks rpt tab
##3.10 NIS domain added to datamovers tab
##############################################################################
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
use Rpt;
use Common;
use NAS::VNX;
################################################################################
## global declarations
################################################################################
use vars qw($VERSION $mail_to @email_rpt @hw_rpt @rpt @error_rpt);
use vars qw($verbose $debug $excel_file);
use vars qw($hosts);
use vars qw(@nas_pools_rpt @nas_pools_rpt_headers @interface_rpt);
##$vnx= object for each vnx, needs to be undef at start of each big loop
use vars qw($vnx $fresh);
use vars qw(@email_rpt_headers @i_headers);
use vars qw(@fs_rpt_headers @fs_rpt $usermapper);
use vars qw(@cifs_servers_rpt @cifs_servers_headers);
use vars qw(@exports_view_rpt @exports_view_headers);
use vars qw(@replicate_rpt @replicate_rpt_headers);
use vars qw(@ckpt_rpt @ckpt_rpt_headers);
use vars qw(%nas_srvs %vdm_srvs);
use vars qw(@tree_quota_rpt @tree_quota_rpt_headers);
use vars qw(@usermapper_rpt @usermapper_rpt_headers);
use vars qw(@virus_rpt @virus_rpt_headers);
use vars qw(@checkers_rpt @checkers_rpt_headers);
use vars qw(@ckpt_sched_rpt @ckpt_sched_rpt_headers);
use vars qw(@param_rpt @param_rpt_headers %all_parms);
use vars qw(@dm_rpt @dm_rpt_headers);
use vars qw(@disk_rpt @disk_rpt_headers);

use subs qw(get_cs_ip prep_email prep_excel send_email);
use subs qw(prep_email_rpt email_headers);
use subs qw(prep_interface_rpt prep_fs_rpt prep_cifs_servers_rpt);
use subs qw(prep_exports_view_rpt prep_nas_pools_rpt);
use subs qw(prep_replicate_rpt prep_ckpt_rpt);
use subs qw(prep_tree_quota_rpt prep_usr_map_rpt);
use subs qw(prep_usermapper_rpt prep_virus_rpt prep_ckpt_schedule);
use subs qw(get_srv_param prep_param_rpt prep_dm_rpt);
use subs qw(prep_disks_rpt);

my $max_arrays=0; #used to count the num of disk arrays per vnx for header
#########################################################################
#process command line
#########################################################################
exit 1 unless GetOptions(
          'f|fresh' => \$fresh,
	  'v' => \$verbose,
	  'm|mail=s' => \$mail_to,
          'h|host=s' => \@$hosts,
          'u|usermapper' => \$usermapper,
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
#@$hosts=('ndhnas500');
#########################################################################
## MAIN
#########################################################################
foreach my $curr_host (@$hosts){
   $com->add_to_log("INFO ".curr_date_time." host=>$curr_host");
   $shared_confs{host}=$curr_host;
   undef $vnx;
   $vnx=VNX->new(\%shared_confs);
   $vnx->verbose(1) if $verbose;
   $vnx->fresh_val(0) if $fresh;
   next if $com->chk_err($vnx,$vnx->chk_host_connect);
   my $cs_ip=get_cs_ip||next;
   my $serial=$vnx->q_serial;
   my $servers=$vnx->q_nas_server;
   undef %nas_srvs;undef %vdm_srvs;
   ##replace server ID's with names:
   foreach (keys %$servers){
     $nas_srvs{$$servers{$_}{Id}}=$_ if ($$servers{$_}{Type} eq 'nas');
     $vdm_srvs{$$servers{$_}{Id}}=$_ if ($$servers{$_}{Type} eq 'vdm');
   }
   prep_disks_rpt;
   prep_dm_rpt;
   get_srv_param;
   prep_ckpt_schedule;
   prep_virus_rpt;
   #prep_usermapper_rpt if $usermapper; 
   prep_tree_quota_rpt;
   prep_ckpt_rpt;
   prep_replicate_rpt;
   prep_nas_pools_rpt;
   prep_exports_view_rpt;
   prep_cifs_servers_rpt;
   prep_fs_rpt;
   prep_interface_rpt;
   prep_email_rpt($cs_ip);
   $com->chk_err($vnx,'fake val');
}#big loop
prep_param_rpt;

unless (@email_rpt){
   $com->add_to_log("no email_rpt report detected");
   push @error_rpt,["all","no @email_rpt report detected"];
}
push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
my $rpt_object=Rpt->new(\%shared_confs);
my $bdir=$rpt_object->daily_rpt_dir;
$rpt_object->daily_rpt_dir("$bdir/$Common::shortname");

prep_excel;
my $html_file="../tmp/$mday$Common::num2mon{$mon}20$YEAR.html";
my $excel_target="$mday$Common::num2mon{$mon}20$YEAR".basename($excel_file);
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
sub prep_disks_rpt{
###############################################################################
 @disk_rpt_headers = (      'VNX',
                            'Array',
                            'Bus_Enclosure_Disk',
                            'Vendor_Id',
                            'Product_Id',
                            'Product_Revision',
                            'Lun',
                            'Type',
                            'State',
                            'Hot_Spare',
                            'Prct_Rebuilt',
                            'Prct_Bound',
                            'Serial_Number',
                            'Sectors',
                            'Capacity',
                            'Private',
                            'Bind_Signature',
                            'Hard_Read_Errors',
                            'Hard_Write_Errors',
                            'Soft_Read_Errors',
                            'Soft_Write_Errors',
                            'Read_Retries',
                            'Write_Retries',
                            'Remapped_Sectors',
                            'Number_of_Reads',
                            'Number_of_Writes',
                            'Number_of_Luns',
                            'Raid_Group_ID',
                            'Clariion_Part_Number',
                            'Request_Service_Time',
                            'Read_Requests',
                            'Write_Requests',
                            'Kbytes_Read',
                            'Kbytes_Written',
                            'Stripe_Boundary_Crossing',
                            'Drive_Type',
                            'Clariion_TLA_Part_Number',
                            'User_Capacity',
                            'Idle_Ticks',
                            'Busy_Ticks',
                            'Current_Speed',
                            'Maximum_Speed',
                          );
    my $disks=$vnx->q_navi_disks;
    return undef if ($com->chk_err($vnx,$disks));
    #print Dumper($disks);exit;
    foreach my $ary (keys %$disks){
        foreach my $disk (keys %{$$disks{$ary}}){
           #print "$ary $disk";
           #print Dumper($$disks{$ary}{$disk});
           my @line;
           push @line,$vnx->host;
           push @line,$ary;
           push @line,$disk;
           foreach my $C (@disk_rpt_headers) {
               next if $C =~ '^VNX$';
               next if $C =~ '^Array$';
               next if $C =~ '^Bus_Enclosure_Disk$';
               #print "C = $C\n";
               #print $$disks{$ary}{$disk}{$C}."\n";
               push @line,$$disks{$ary}{$disk}{$C}|| ' ';
           }#for my $C in @disk_rpt_headers {
           #print "\n";
           push @disk_rpt,[@line];
        }#foreach my $disk (keys %{$$disks{$ary}}){
    }#foreach my $ary (keys %$disks){
    #print Dumper(@disk_rpt);
    #exit;
}
###############################################################################
sub prep_dm_rpt{
###############################################################################
  my $srvs=$vnx->q_nas_server;
  return undef if ($com->chk_err($vnx,'fake value'));
  my $ns=$vnx->q_server_nsdomains;
  return undef if ($com->chk_err($vnx,'fake value'));
  #print Dumper($ns);exit;
  @dm_rpt_headers=('Name','Type','Id  ','PhysicalHost','DNSDomain','MotherBoard','StandbyPolicy','StandbyServer','Version','MemoryUsage ','NtpServers','DNSAddresses','TimeZone','CifsUserMapperPrimary','CPU','CPUSpeed ','CpuUsage ','CifsEnabledInterfaces','CifsUnusedInterfaces','CifsUsedInterfaces','HasNIS ','NIS Domain','Dialect ','Uptime','Model','IsInUse ','HasDNS  ','Status');
  foreach my $dm (keys %$srvs){
    #say $dm;
    my @line;
    my $nis = '<not defined>';
    push @line,$vnx->host;
    foreach (@dm_rpt_headers){
       my $i=$_;
       $i=~s/\s+$//g;
       if ($i =~ /NIS Domain/) {
           $nis = $$ns{$dm}{'NIS'} if ($$ns{$dm}{'NIS'});
           push @line,$nis;
           next;
       }
       if (defined $$srvs{$dm}{$i}){
          push @line,$$srvs{$dm}{$i};
       } else {
          push @line,' ';
       }
    }
    push @dm_rpt,[@line];
  }
  unshift @dm_rpt_headers,'VNX';
 #print Dumper @dm_rpt;
}
###############################################################################
sub prep_param_rpt{
###############################################################################
  return undef unless (%all_parms);
  my %headers;
  foreach  my $srv (keys %all_parms){
    foreach my $parm (keys %{$all_parms{$srv}}){
      $headers{$parm}=1;
    }
    print "\n";
  }
  foreach  my $field (sort keys %headers){
    push @param_rpt_headers,$field;
  }
#print Dumper %all_parms;exit;
  foreach  my $srv (sort keys %all_parms){
    my @line;
    push @line,$srv;
    foreach my $parm (@param_rpt_headers){
      my $val=' ';
      $val=$all_parms{$srv}{$parm} if (defined $all_parms{$srv}{$parm});
      push @line,$val;
    }
    push @param_rpt,[@line];
  }
  unshift @param_rpt_headers,'VNX DM';
}
###############################################################################
sub get_srv_param{
###############################################################################
  my $srv_parms=$vnx->q_server_param;
  foreach my $srv (keys %$srv_parms){
     my $issue_flag;
     foreach my $fac (keys %{$$srv_parms{$srv}}){
        foreach my $parm (keys %{$$srv_parms{$srv}{$fac}}){
            my $vnx_dm=$vnx->host." $srv";
            my $curr=' ';
            if (defined $$srv_parms{$srv}{$fac}{$parm}{current}){
              $curr=$$srv_parms{$srv}{$fac}{$parm}{current};
            } 
            $all_parms{$vnx_dm}{"$fac $parm"}=$curr;
        }#foreach my $parm
     }#foreach my $fac
  }#forach my $srv
}
###############################################################################
sub prep_ckpt_schedule{
###############################################################################
#use vars qw(@ckpt_sched_rpt @ckpt_sched_rpt_headers);
  my $sched=$vnx->q_nas_ckpt_schedule;
  return undef if $com->chk_err($vnx,$sched);
  @ckpt_sched_rpt_headers=('VNX ','CKPT Name ','CKPT ID ','FS Name ','FS ID ','At Which Times','On Which Days of Week','On Which Days of Month','State ','Description ','Tasks ','Next Run','Start On','End On');
  foreach (sort keys %$sched){
    #print "ID $_ \n";
    push @ckpt_sched_rpt,[
                         $vnx->host,
                         $$sched{$_}{Name}|| ' ',
                         $_,
                         $$sched{$_}{fs_name}|| ' ',
                         $$sched{$_}{fs_id}|| ' ',
                         $$sched{$_}{At_Which_Times}|| ' ',
                         $$sched{$_}{On_Which_Days_of_Week}|| ' ',
                         $$sched{$_}{On_Which_Days_of_Month}|| ' ',
                         $$sched{$_}{State}|| ' ',
                         $$sched{$_}{Description}|| ' ',
                         $$sched{$_}{Tasks}|| ' ',
                         $$sched{$_}{Next_Run}|| ' ',
                         $$sched{$_}{Start_On}|| ' ',
                         $$sched{$_}{End_On}|| ' ',
                         ];
  }# foreach (sort keys %$sched){
}
###############################################################################
sub prep_virus_rpt{
###############################################################################
   my $vchk=$vnx->q_server_viruschk;
   return undef if $com->chk_err($vnx,$vchk);
   return undef unless (%nas_srvs);
   my %srvs=reverse %nas_srvs;
   foreach my $dm (sort keys %$vchk){
      next unless $srvs{$dm};#to skip standby's
      my $addr_list;
      foreach my $addr (keys %{$$vchk{$dm}}){
        if ($addr =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/i){
           $addr_list.="$addr ";
           push @virus_rpt,[
                              $vnx->host,
                              $dm,
                              $$vchk{$dm}{$addr}{server_name}||' ',
                              $$vchk{$dm}{$addr}{status}||' ',
                              $$vchk{$dm}{$addr}{engine}||' ',
                              $$vchk{$dm}{$addr}{cava_version}||' ',
                              $$vchk{$dm}{$addr}{last_sig}||' ',
                              $$vchk{$dm}{$addr}{status_date}||' ',
                              $$vchk{$dm}{$addr}{protocol}||' ',
                              $$vchk{$dm}{$addr}{ntstatus}||' ',
                              ' ',' ',' ',' ',' ',' ',' ',
                              ' ',' ',' ',' ',' ',' ',' ',
                              ];
        }#if ($addr =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/i){
      }#foreach my $addr (keys %{$$vchk{$dm}}){
      push @virus_rpt,[
                      $vnx->host,
                      $dm,
                      ' ',' ',' ',' ',' ',' ',' ',
                      $$vchk{$dm}{server_status}||' ',
                      $$vchk{$dm}{share}||' ',
                      $$vchk{$dm}{user}||' ',
                      $$vchk{$dm}{low_water_mark}||' ',
                      $$vchk{$dm}{high_water_mark}||' ',
                      $$vchk{$dm}{panic_handler}||' ',
                      $$vchk{$dm}{rpc_request_timeout}||' ',
                      $$vchk{$dm}{rpc_retry_timeout}||' ',
                      $$vchk{$dm}{scan_rate}||' ',
                      $$vchk{$dm}{access_time}||' ',
                      $$vchk{$dm}{clientname}||' ',
                      $$vchk{$dm}{file_mask}||' ',
                      $$vchk{$dm}{excluded_files_count}||' ',
                      $$vchk{$dm}{excluded_files}||' ',
                      $$vchk{$dm}{checkers}||' ',
                      ];
   }#foreach my $dm (sort keys %$vchk){
   @virus_rpt_headers=('VNX ','datamover ','CAVA server ','status ','engine ','cava_version ','last sig ','status date','protocol ','nstatus ','share ','user ','low_water_mark ','high_water_mark ','panic_handler ','rpt_request_time ','rpc_retry_timeout','scan_rate ','access_time ','clientname ','file_mask ','excluded_files_count ','excluded_files ','checkers ');
}
###############################################################################
sub prep_usermapper_rpt{
###############################################################################
   return undef unless $vnx->primary_usermapper;
   my ($map_srv,$map_dm)=split(/\s+/,$vnx->primary_usermapper);
   return undef unless (lc $vnx->host eq lc $map_srv);
   return undef  unless $map_dm;
   my $map=$vnx->server_usermapper_user($map_dm) if ($map_dm);
   return undef unless ($map);
   foreach (@$map){
     #print "$_\n";
     my ($sid,$null,$uid,$gid,$descrip,$homedir,$ushell)=split (/:/,$_);
     next unless $descrip;
     my ($u,$user,$from,$d,$domain)=split /\s+/,$descrip;
     push @usermapper_rpt,[
          $user,              
          $domain,              
          $uid,
          $sid,
     ]
   }
   #print Dumper(@usermapper_rpt);
   @usermapper_rpt_headers=('User','Domain','UID','SID');
}
###############################################################################
sub prep_tree_quota_rpt{
###############################################################################
  my $qts=$vnx->q_nas_fs_tree_quotas;
  return undef if ($com->chk_err($vnx,'fake value'));
  @tree_quota_rpt_headers=('VNX','FileSystem','Path','ID  ','Usage  ','HardLimit','SoftLimit','Comment ','RWVDMs','RWServers','RWMountpoint','Block Time Left','BlockDefaultGracePeriod','IsHardLimitEnforced','InodeUsage ');
  foreach my $pfs (sort {lc $a cmp lc $b} keys %$qts){
     foreach my $path (keys %{$$qts{$pfs}}){
        #print "filesystem $pfs  path $path ".$$qts{$pfs}{$path}{RWServers}."\n";
        push @tree_quota_rpt,[
                             $vnx->host,
                             $pfs,
                             $path,
                             $$qts{$pfs}{$path}{ID}||' ',
                             $$qts{$pfs}{$path}{BlockUsage}||' ',
                             $$qts{$pfs}{$path}{BlockHardLimit}||' ',
                             $$qts{$pfs}{$path}{BlockSoftLimit}||' ',
                             $$qts{$pfs}{$path}{Comment}||' ',
                             $$qts{$pfs}{$path}{RWVDMs}||' ',
                             $$qts{$pfs}{$path}{RWServers}||' ',
                             $$qts{$pfs}{$path}{RWMountpoint}||' ',
                             $$qts{$pfs}{$path}{BlockTimeLeft}||' ',
                             $$qts{$pfs}{$path}{DefaultBlockGracePeriod}||' ',
                             $$qts{$pfs}{$path}{IsHardLimitEnforced}||' ',
                             $$qts{$pfs}{$path}{InodeUsage}||' '
                             ];
     }
  }
}
###############################################################################
sub prep_ckpt_rpt{
###############################################################################
  my $ckpts=$vnx->q_nas_fs_ckpt;
  return undef if ($com->chk_err($vnx,'fake value'));
  @ckpt_rpt_headers=('VNX','Ckpt ','BackupOf ','SizeMB  ','BackupTimeStamp','CkptPctUsed','CkptSavVolUsedMB','ID ','BaselineCkptName','InUse  ','IsInactive');
  #print Dumper($ckpts);
  #lets create hash of PFS file system names for later sorting
  my (%fs);
  foreach (keys %$ckpts){
    $fs{$$ckpts{$_}{BackupOf}}=1;
  }
  foreach my $pfs (sort {lc $a cmp lc $b} keys %fs){
    #print "PFS $pfs\n";
    foreach (keys %$ckpts){
      next unless ($$ckpts{$_}{BackupOf} eq $pfs);
      push @ckpt_rpt,[
         $vnx->host,
         $$ckpts{$_}{Name},
         $$ckpts{$_}{BackupOf},
         $$ckpts{$_}{Size},
         strftime("%m/%d/%Y %H:%M:%S",localtime $$ckpts{$_}{BackupTimeStamp}),
         $$ckpts{$_}{CkptPctUsed},
         $$ckpts{$_}{CkptSavVolUsedMB},
         $$ckpts{$_}{ID},
         $$ckpts{$_}{BaselineCkptName},
         $$ckpts{$_}{InUse},
         $$ckpts{$_}{IsInactive},
      ]#push @ckpt_rpt,
    }#foreach (keys %$ckpts){
  }#foreach my $pfs
  #print Dumper(@ckpt_rpt);
}
###############################################################################
sub prep_replicate_rpt{
###############################################################################
  my $repl=$vnx->q_nas_replicate;
  return undef if ($com->chk_err($vnx,'fake value'));
  #my $nas_cel=$vnx->q_nas_cel;
  #print Dumper(%$repl);
  foreach (keys %$repl){
    next unless ($$repl{$_}{localRole}=~/source/);
    #s/^"(.*)"$/$1/g;
    push @replicate_rpt,[
           $vnx->host,
           $$repl{$_}{name}||' ',
           $$repl{$_}{id}||' ',
           $$repl{$_}{sourceStatus}||' ',
           $$repl{$_}{networkStatus}||' ',
           $$repl{$_}{destinationStatus}||' ',
           $$repl{$_}{lastSyncTime}||' ',
           $$repl{$_}{object}||' ',
           $$repl{$_}{dartInterconnect}||' ',
           $$repl{$_}{peerInterconnect}||' ',
           $$repl{$_}{localRole}||' ',
           $$repl{$_}{sourceFilesystem}||' ',
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
           $$repl{$_}{remoteSystem}||' ',
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
  @replicate_rpt_headers=('VNX ','name ','id','sourceStatus','networkStatus','destinationStatus','lastSyncTime ','object ','dartInterconnect','peerInterconnect','localRole ','sourceFilesystem','sourceVdm','sourceMover','sourceInterface','sourceControlPort','curTransferSourceDataPort','destinationFilesystem ','destinationVdm','destinationMover','destinationInterface','destinationControlPort','destinationDataPort','maxTimeOutOfSync','curTransferTotalSizeKB','curTransferRemainSizeKB','curTransferEstEndTime','curTransferIsFullCopy','curTransferRateKB','curReadRateKB','curWriteRateKB','prevTransferRateKB','prevReadRateKB','prevWriteRateKB','avgTransferRateKB','avgReadRateKB','avgWriteRateKB','remoteSystem','isCopy ','internalSnaps','latestSrcSnap','curTransferSnap','latestDstSnap','waitingSnaps','sourceTarget','destinationTarget','appData ','sourceLun ','destinationLun' );


            #'destinationControlPort' => '"5085"',
            #'remoteSystem' => '"4"',
            #'destinationFilesystem' => '"1042"',
            #'curReadRateKB' => '"0"',
            #'waitingSnaps' => '""',
            #'appData' => '""',
            #'avgReadRateKB' => '"1025"',
            #'prevTransferRateKB' => '"10204"',
            #'sourceControlPort' => '"0"',
            #'isCopy' => '"false"',
            #'sourceVdm' => '""',
            #'id' => '"700_FNM00085200076_00E0_1619_APM00131211103_2007"',
            #'destinationLun' => '""',
            #'prevReadRateKB' => '"388"',
            #'peerInterconnect' => '"30004"',
            #'curTransferIsFullCopy' => '"No"',
            #'sourceInterface' => '"10.138.70.13"',
            #'internalSnaps' => '"2212:2211:1045:1044"',
            #'avgWriteRateKB' => '"2956"',
            #'name' => '"REP_credstar"',
            #'maxTimeOutOfSync' => '"10"',
            #'destinationTarget' => '""',
            #'dartInterconnect' => '"30003"',
            #'destinationMover' => '"server_3"',
            #'latestSrcSnap' => '"700.ckpt002"',
            #'destinationStatus' => '"OK"',
            #'sourceMover' => '"server_3"',
            #'sourceLun' => '""',
            #'prevWriteRateKB' => '"2333"',
            #'object' => '"filesystem"',
            #'destinationVdm' => '""',
            #'destinationDataPort' => '"8888"',
            #'curTransferRemainSizeKB' => '"0"',
            #'curTransferEstEndTime' => '""',
            #'curTransferSourceDataPort' => '"0"',
            #'sourceStatus' => '"OK"',
            #'networkStatus' => '"OK"',
            #'curTransferSnap' => '""',
            #'destinationInterface' => '"10.208.200.12"',
            #'latestDstSnap' => '"1619.ckpt001"',
            #'curTransferTotalSizeKB' => '"0"',
            #'curTransferRateKB' => '"0"',
            #'lastSyncTime' => '"24 Mar 2014 07:02:20"',
            #'avgTransferRateKB' => '"5029"',
            #'sourceTarget' => '""',
            #'localRole' => '"destination"',
            #'sourceFilesystem' => '"267"',
            #'curWriteRateKB' => '"0"'
}
###############################################################################
sub prep_nas_pools_rpt{
###############################################################################
  my $pools=$vnx->q_nas_pool;
  return undef if ($com->chk_err($vnx,'fake value'));
  #print Dumper($pools);
  @nas_pools_rpt_headers=('VNX','Name','ID  ','AvailableMB','UsedMB ','CapacityMB ','PotentialMB','Desc','DiskType ','IsInUse ','IsUserDefined','IsDynamic ','IsGreedy ','StorageIDs');
  foreach (keys %$pools){
    push @nas_pools_rpt,[
           $vnx->host,
           $_,
           $$pools{$_}{ID},
           $$pools{$_}{AvailableMB}||' ',
           $$pools{$_}{UsedMB}||' ',
           $$pools{$_}{CapacityMB}||' ',
           $$pools{$_}{PotentialMB}||' ',
           $$pools{$_}{Desc}||' ',
           $$pools{$_}{DiskType}||' ',
           $$pools{$_}{IsInUse}||' ',
           $$pools{_}{IsUserDefined}||' ',
           $$pools{$_}{IsDynamic}||' ',
           $$pools{$_}{IsGreedy}||' ',
           $$pools{$_}{StorageIDs}||' ',
                         ];
  }#foreach (keys %pools){
}
###############################################################################
sub prep_exports_view_rpt{
###############################################################################
  my $exports=$vnx->q_server_export;
  return undef if ($com->chk_err($vnx,'fake value'));
  my $nas_fs=$vnx->q_nas_fs;
  return undef if ($com->chk_err($vnx,'fake value'));
  my $mnts=$vnx->q_server_mount;
  return undef if ($com->chk_err($vnx,'fake value'));
  my $c_srvs=$vnx->q_server_cifs;
  return undef if ($com->chk_err($vnx,'fake value'));
  my @sorted;

  my $qts=$vnx->q_nas_fs_tree_quotas;
  #print Dumper($mnts);
  #print Dumper ($exports);
  #exit;
  my $fs_not_found=1;
  foreach my $srv (keys %$exports){
    foreach my $path (keys %{$$exports{$srv}}){
      #next unless $path =~ 'ndh503v02fsl005';
      #print "$srv $path\n";
      foreach my $ary (@{$$exports{$srv}{$path}}){
         my ($fs_name,$security);
         #print Dumper (%$ary);
         #print $$ary{protocol}." $srv $path ";
         my $mnt=$$ary{mnt}||undef;
         unless ($mnt){
            $fs_not_found++;
            $fs_name="fs_mnt_not_found_$fs_not_found";
         }else{
            #print "$mnt ";
            $fs_name=$$mnts{$srv}{$mnt}{fs}||"fs_not_found_$fs_not_found";
            $security=$$mnts{$srv}{$mnt}{security}||" ";
         }
         my $rw_srv=$$nas_fs{$fs_name}{RWServersNumeric};
         $rw_srv=$nas_srvs{$rw_srv} if ($rw_srv);
         my $rw_vdm=$$nas_fs{$fs_name}{RWVDMsNumeric};
         $rw_vdm=~s/v//g if ($rw_vdm);
         $rw_vdm=$vdm_srvs{$rw_vdm} if ($rw_vdm);
         my $ro_srv=$$nas_fs{$fs_name}{ROServersNumeric};
         $ro_srv=$nas_srvs{$ro_srv} if ($ro_srv);
         my $ro_vdm=$$nas_fs{$fs_name}{ROVDMsNumeric};
         $ro_vdm=~s/v//g if ($ro_vdm);
         $ro_vdm=$vdm_srvs{$ro_vdm} if ($ro_vdm);
         my $cifs_domain;
         if ( $$ary{netbios} ){
           $cifs_domain=$$c_srvs{$srv}{$$ary{netbios}}{CifsDomain}||' ';
         }
         my $quota_path=$path;
         $quota_path=~s/\/$fs_name//;

         push @sorted,[
              $fs_name,
              $$ary{protocol}||' ',
              $$ary{share}||' ',
              $path,
              $vnx->host,
              $$ary{netbios}||' ',
              $cifs_domain||' ',
              $$ary{comment}||' ',
              $$nas_fs{$fs_name}{fs_cap}||' ',
              $$nas_fs{$fs_name}{fs_avail}||' ',
              $$qts{$fs_name}{$quota_path}{BlockUsage}||' ',
              $$qts{$fs_name}{$quota_path}{BlockSoftLimit}||' ',
              $$qts{$fs_name}{$quota_path}{BlockHardLimit}||' ',
              $$qts{$fs_name}{$quota_path}{InodeUsage}||' ',
              $rw_srv||' ',
              $rw_vdm||' ',
              $ro_srv||' ',
              $ro_vdm||' ',
              $$ary{mnt}||' ',
              $security||' ',
              $$ary{root}||' ',
              $$ary{rw}||' ',
              $$ary{ro}||' ',
              $$ary{access}||' ',
              $$nas_fs{$fs_name}{Replications}||' ',
                       ];
      }#foreach my $ary (@{$$exports{$srv}{$path}}){
    }#foreach my $path (keys %{$$exports{$srv}}){
  }#foreach my $srv (keys %$exports){
  @sorted=sort{$a->[0] cmp $b->[0]} @sorted;
  push @exports_view_rpt,@sorted;
  
  @exports_view_headers=('FS Name','Type  ','Share name','Path','VNX','NETBIOS','AD Domain ','Export Comment','FS capacity MB','FS available MB','Tree Quota Use','Tree Quota Soft Limit','Tree Quota Hard Limit','InodeUsage ','RW DM','RW VDM',,'RO DM','RO VDM','Mountpoint','Mount Options','root=','rw=','ro=','access=','Replications');
}
###############################################################################
sub prep_cifs_servers_rpt{
###############################################################################
  my $c_srvs=$vnx->q_server_cifs;
  #print "################ HERE        ##########";
  #print Dumper($c_srvs); exit;
  return undef if ($com->chk_err($vnx,'fake value'));
   foreach (keys %$c_srvs){
     foreach my $c (keys %{$$c_srvs{$_}}){
       push @cifs_servers_rpt,[
          $vnx->host,
          $_,
          $c,
          $$c_srvs{$_}{$c}{CifsDomain}||' ',
          $$c_srvs{$_}{$c}{CifsInterfaceAddresses}||' ',
          $$c_srvs{$_}{$c}{Compname}||' ',
          $$c_srvs{$_}{$c}{Realm}||' ',
          $$c_srvs{$_}{$c}{Computername}||' ',
          $$c_srvs{$_}{$c}{Netbios}||' ',
          $$c_srvs{$_}{$c}{IsDefault}||' ',
          $$c_srvs{$_}{$c}{HasJoinedDomain}||' ',
          $$c_srvs{$_}{$c}{HomeShare}||' ',
          $$c_srvs{$_}{$c}{Aliases}||' ',
          $$c_srvs{$_}{$c}{LocalUsersEnabled}||' ',
          $$c_srvs{$_}{$c}{CifsType}||' ',
          $$c_srvs{$_}{$c}{Authentication}||' ',
          $$c_srvs{$_}{$c}{Comment}||' ',
                            ];
     }#foreach my $c (keys %{$$c_srvs{$_}}{
   }#foreach (keys %$c_srvs{
   @cifs_servers_headers=('VNX ','Datamover ','CIFS Server ','Domain  ','Interfaces','Compname ','Realm ', 'Computername ','Netbios ','IsDefault ','HasJoinedDomain ','HomeShare ','Aliases','LocalUsersEnabled','CifsType ','Authentication','Comment');
}
###############################################################################
sub prep_fs_rpt{
###############################################################################
  my $dfi=$vnx->server_df_i;
  return undef if ($com->chk_err($vnx,'fake value'));
  #print Dumper($dfi);exit;
  my $exports=$vnx->q_server_export;
  return undef if ($com->chk_err($vnx,'fake value'));
  my $ckpts=$vnx->q_nas_fs_ckpt;
  return undef if ($com->chk_err($vnx,'fake value'));
  #create hash from ckpts with fs as key and highest size ckpt
  my %fs_ckpt;
  foreach (keys %$ckpts){
    my $fs=$$ckpts{$_}{BackupOf};
    my $size=$$ckpts{$_}{Size};
    $fs_ckpt{$fs}=$size;
  }
  ##create hash to test cifs or nfs mount:
  my %export_mnts;
  foreach my $srv (keys %$exports){
    foreach my $path (keys %{$$exports{$srv}}){
      #print "$srv $path\n";
      foreach my $ary (@{$$exports{$srv}{$path}}){
         my $type=$$ary{protocol};
         my $mnt=$$ary{mnt}||next;
         $export_mnts{$srv}{$type}{$mnt}=1;
      }
    }
  }
  my $fs=$vnx->q_nas_fs;
  return undef if ($com->chk_err($vnx,'fake value'));
  #print Dumper(%$fs);
  foreach my $name (keys %$fs){
      #print "name=>$name\n";
      next unless ($$fs{$name}{Type} and $$fs{$name}{Type}=~/uxfs/);
      my $rw_srv=$$fs{$name}{RWServersNumeric};
      $rw_srv=$nas_srvs{$rw_srv} if ($rw_srv);
      my $rw_vdm=$$fs{$name}{RWVDMsNumeric};
      $rw_vdm=~s/v//g if ($rw_vdm);
      $rw_vdm=$vdm_srvs{$rw_vdm} if ($rw_vdm);
      my $ro_srv=$$fs{$name}{ROServersNumeric};
      $ro_srv=$nas_srvs{$ro_srv} if ($ro_srv);
      my $ro_vdm=$$fs{$name}{ROVDMsNumeric};
      $ro_vdm=~s/v//g if ($ro_vdm);
      $ro_vdm=$vdm_srvs{$ro_vdm} if ($ro_vdm);

      my ($nfs,$cifs);
      if ($$fs{$name}{RWMountPoint}){
        my $scrub_mnt=$$fs{$name}{RWMountPoint};
        $scrub_mnt=~s/^\/root_vdm_\d+//;
          if ($rw_srv and $export_mnts{$rw_srv}{NFS}{$scrub_mnt}){$nfs='yes'}
          if ($rw_vdm and $export_mnts{$rw_vdm}{NFS}{$scrub_mnt}){$nfs='yes'}
          if ($rw_srv and $export_mnts{$rw_srv}{CIFS}{$scrub_mnt}){$cifs='yes'}
          if ($rw_vdm and $export_mnts{$rw_vdm}{CIFS}{$scrub_mnt}){$cifs='yes'}
      }
    my $max_size=$$fs{$name}{MaxSize}||' ';
    if ((!defined $$fs{$name}{AutoExtend}) or ($$fs{$name}{AutoExtend} eq 'False')){
       $max_size=' ' ;
    }
    if ($$fs{$name}{VirtuallyProvisioned} eq 'False'){
       $max_size=' ' ;
    }
    my $max_size_reached = 'False ';
    if ($max_size eq $$fs{$name}{Size}){
       $max_size_reached = 'True ';
    }
    push @fs_rpt,[
      $vnx->host,
      $$fs{$name}{ID},
      $name,
      $$fs{$name}{Size},
      $max_size,
      $max_size_reached,
      $$fs{$name}{fs_cap},
      $$fs{$name}{fs_avail},
      $$fs{$name}{fs_used},
      $$fs{$name}{fs_percent},
      #$$fs{$name}{InodeCount}, ##This is capaicity,not needed for rpt.
      $$dfi{$name}{used}||' ',
      $fs_ckpt{$name}||' ',
      $$fs{$name}{PoolId}||' ',
      $$fs{$name}{StoragePoolName}||' ',
      #$srvs{$$fs{$name}{RWServersNumeric}}||' ',
      #$srvs{$$fs{$name}{RWVDMsNumeric}}||' ',
      #$srvs{$$fs{$name}{ROServersNumeric}}||' ',
      #$srvs{$$fs{$name}{ROVDMsNumeric}}||' ',
      $rw_srv||' ',
      $rw_vdm||' ',
      $ro_srv||' ',
      $ro_vdm||' ',
      $$fs{$name}{RWMountPoint}||' ',
      $$fs{$name}{VirtuallyProvisioned}||' ',
      $$fs{$name}{AutoExtend}||' ',
      $$fs{$name}{HWMNumber}||' ',
      $$fs{$name}{IsInUse}||' ',
      $$fs{$name}{IsUSerQuotasEnabled}||' ',
      $$fs{$name}{IsGroupQuotasEnabled}||' ',
      $$fs{$name}{IsHardLimitEnforced}||' ',
      $$fs{$name}{HasiSCSILun}||' ',
      $nfs||' ',
      $cifs||' '
                 ];
  }#foreach my $name (keys %$fs){
   @fs_rpt_headers=('VNX','FS ID ','FS Name ','Vol Total MB Size ','Maxsize ','Max Size Reached','FS MB Capacity ','FS Avail MB ','FS Used MB ','FS Utilized %','InodesUsed','SavvolMB ','Pool ID ','Pool Name ','RW server ','RW VDM  ','RO server  ','RO VDM  ','RW Mount Point ','VirtuallyProvisioned','AutoExtend  ','HWM   ','IsInUse ','IsUSerQuotasEnabled ','IsGroupQuotasEnabled ','IsHardLimitEnforced ','HasiSCSILun ','RW NFS Detected ','RW CIFS detected ');
}
###############################################################################
sub prep_interface_rpt{
###############################################################################
  @i_headers=('VNX','datamover ','Name','Address ','VLAN  ','Status ','MAC ','Device ','Device Type','MTU   ','Netmask ','Broadcast ');
  my $interfaces=$vnx->q_server_ifconfig;
  return undef if ($com->chk_err($vnx,'fake value'));
  #print Dumper(%$interfaces);
  foreach my $srv (sort keys %$interfaces){
     foreach my $if (keys %{$$interfaces{$srv}}){
        #print "$srv $if\n";
        push @interface_rpt,[
                       $vnx->host,
                       $srv,
                       $if,
                       $$interfaces{$srv}{$if}{Address}||' ',
                       $$interfaces{$srv}{$if}{VLAN}||'0',
                       $$interfaces{$srv}{$if}{Status}||' ',
                       $$interfaces{$srv}{$if}{MAC}||' ',
                       $$interfaces{$srv}{$if}{Device}||' ',
                       $$interfaces{$srv}{$if}{DeviceType}||' ',
                       $$interfaces{$srv}{$if}{MTU}||' ',
                       $$interfaces{$srv}{$if}{Subnet}||' ',
                       $$interfaces{$srv}{$if}{Broadcast}||' ',
                            ];
     }
  }
}
###############################################################################
sub prep_email_rpt{
###############################################################################
   #@email_rpt_headers=email_headers;
   #print Dumper (@email_rpt_headers);
   my $cs_ip=shift;
   my @s_arrays;
   my $nas_stor=$vnx->q_nas_storage_sum;
   my $nas_stor_procs=$vnx->q_nas_storage_procs;
   #print Dumper($nas_stor_procs);
   #print Dumper($nas_stor);
   my $curr_size=scalar (keys %$nas_stor);
   if ($max_arrays lt  $curr_size){
      $max_arrays = $curr_size ;
   }
    
   foreach (keys %$nas_stor){
     my $serial=$$nas_stor{$_}{Serial};
     #print "serial $serial\n";
     #foreach my $SP (keys %{$$nas_stor_procs{$serial}}){
       #print "SP $SP ".$$nas_stor_procs{$serial}{$SP}{Address}."\n";
     #}
     push @s_arrays,
                    $serial||' ',
                    $$nas_stor{$_}{UcodePatchLevel}||' ',
                    $$nas_stor_procs{$serial}{A}{Version}||' ',
                    $$nas_stor_procs{$serial}{A}{Address}||' ',
                    $$nas_stor_procs{$serial}{B}{Address}||' '
                    ;
   }#foreach (keys %$nas_stor){
   push @email_rpt,[
        $vnx->host,
        $cs_ip||' ',
        $vnx->q_serial||' ',
        $vnx->q_model||' ',
        #$$s_version{server_2},
        ${$vnx->q_server_version}{server_2},
        @s_arrays
                   ];
   #print Dumper(@email_rpt);
   #exit;
}
###############################################################################
sub get_cs_ip{
###############################################################################
   my $option;
   if ($^O eq 'linux'){
      $option='-c';
   }else{
      $option='-n';
   }
   my $cmd="ping $option 1 ".$vnx->host;
   my ($stdout,$stderr)=run_cmd($cmd);
   if (@$stderr){
      say "STDERR $_" foreach (@$stderr);
      my $combined=join " ",@$stderr;
      push @error_rpt,"ERROR with get_cs_ip: $combined";
      return undef;
   }
   foreach (@$stdout){
       print "$_\n" if $verbose;
       return $1 if (/Reply from (\S+):/);##windows
       return $1 if (/^PING\s+\S+\s+\((\S+)\)/);##linux
   }
   return undef;
}

###############################################################################
sub email_headers{
###############################################################################
   #print Dumper(@email_rpt);
   my @header=('VNX','CS IP ','Serial ','Model ','Dart ');
   #say "max arrays $max_arrays";
   my $cnt=0;
   foreach my $outer (@email_rpt){
   }
   while ($cnt != $max_arrays){
      push @header,'Array serial','Array Model','Array Firmware','SPA','SPB';
      $cnt++;
   }
   #print Dumper(@header);
   return \@header;
    
}
###############################################################################
sub prep_email{
###############################################################################
   my $headers=email_headers;
   my @eheaders;
   $rpt_object->MakeEmailBodyHeaders('VNX Inventory','',\@eheaders);
   if (@error_rpt) {
     my @status_rpt;
     push @status_rpt,"Errors detected:";
     $rpt_object->MakeEmailStatusHeaders('Red',\@status_rpt);
     my @error_table_headers=qw(VNX Error_Message);
     $rpt_object->MakeEmailBody(\@error_table_headers,\@error_rpt);
     $rpt_object->email("<BR>&nbsp;<BR>\n");
     undef @status_rpt;
   }
   $rpt_object->MakeEmailBody($headers,\@email_rpt) if @email_rpt;
   my @footers;
   push @footers,"$Common::basename ver $VERSION";
   $rpt_object->MakeEmailFooter(\@footers);
   return 1;
}
###########################################################################
sub prep_excel{
###########################################################################
   my $headers=email_headers;
   $excel_file="../tmp/vnx_rpt.xlsx";
   $com->add_to_log("INFO making excel $excel_file");
   return undef unless (@email_rpt);
   $rpt_object->excel_file($excel_file);
   $rpt_object->excel_tabs('HW Rpt',$headers,\@email_rpt,1) if @email_rpt;
   $rpt_object->excel_tabs('File Pools',\@nas_pools_rpt_headers,\@nas_pools_rpt,1) if @nas_pools_rpt;
#print Dumper(@exports_view_headers);exit;
   my %formats;
   $formats{'all'}{2}{'width'}=32.5;
   $formats{'all'}{3}{'width'}=62.5;
   $formats{'all'}{7}{'width'}=32.5;
   $formats{'all'}{17}{'width'}=62.5;
   $formats{'all'}{18}{'width'}=62.5;
   $formats{'all'}{19}{'width'}=62.5;
   $formats{'all'}{20}{'width'}=62.5;
   $formats{'all'}{21}{'width'}=62.5;
   $rpt_object->excel_tabs('Exports view',\@exports_view_headers,\@exports_view_rpt,1,\%formats) if @exports_view_rpt;
   $rpt_object->excel_tabs('File Systems',\@fs_rpt_headers,\@fs_rpt,3) if @fs_rpt;
   $rpt_object->excel_tabs('Tree Quotas',\@tree_quota_rpt_headers,\@tree_quota_rpt,3) if @tree_quota_rpt;
   $rpt_object->excel_tabs('Interfaces',\@i_headers,\@interface_rpt,1) if @interface_rpt;
   $rpt_object->excel_tabs('CIFS Servers',\@cifs_servers_headers,\@cifs_servers_rpt,1) if @cifs_servers_rpt;
   $rpt_object->excel_tabs('Src Replications',\@replicate_rpt_headers,\@replicate_rpt,1) if @replicate_rpt;
   $rpt_object->excel_tabs('Checkpoints',\@ckpt_rpt_headers,\@ckpt_rpt,1) if @ckpt_rpt;
   $rpt_object->excel_tabs('Checkpoint Schedules',\@ckpt_sched_rpt_headers,\@ckpt_sched_rpt,1) if @ckpt_sched_rpt;
   $rpt_object->excel_tabs('Viruschk',\@virus_rpt_headers,\@virus_rpt,1) if @virus_rpt;
   $rpt_object->excel_tabs('Datamovers',\@dm_rpt_headers,\@dm_rpt,2) if @dm_rpt;
   $rpt_object->excel_tabs('Server Params',\@param_rpt_headers,\@param_rpt,1) if @param_rpt;
   $rpt_object->excel_tabs('Primary Usermapper',\@usermapper_rpt_headers,\@usermapper_rpt,1) if @usermapper_rpt;
   $rpt_object->excel_tabs('Disks',\@disk_rpt_headers,\@disk_rpt,3) if @disk_rpt;
   $rpt_object->write_excel_tabs if ($rpt_object->excel_tabs);
}
###########################################################################
sub send_email{
###########################################################################
   $rpt_object->email_subject("$configs{email_subject} ".curr_date_time) if ($configs{email_subject});
   $com->add_to_log("INFO sending email to ".$rpt_object->email_to);
   $rpt_object->email_attachment($excel_file) if (-f $excel_file);
   copy $excel_file,$rpt_object->daily_rpt_dir;
   $rpt_object->SendEmail;# unless ($mail_to eq 'none')
   unlink($excel_file) if (-f $excel_file);
}
