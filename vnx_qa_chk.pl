#!/usr/bin/perl -w
##############################################################################
## qa_rpt.pl
my $VERSION=3.10;
## Written by Michael Denney (michael.s.denney@gmail.com)
##
## Report on VNX-FILE Quality Assurance check
##############################################################################
##HISTORY
#1.01 initial release
#1.03 use NAS::VNX
#1.04 appendixA.vals
#1.06 copy files to daily
#1.07 --host should work now
#2.01 security settings checks
#2.11 password_rules checks
#2.20 chk_ports
#2.21 vnx.conf
#2.22 -m fix
#2.23 push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
#3.00 ports_rpt tab
#3.10 Check for audit_tool : sub chk_audit
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX;
use Time::Local;
use File::Basename;
use File::Copy;
use Data::Dumper;
use IO::Socket;
use IO::Socket::PortState qw(check_ports);
use Getopt::Long;
use Rpt;
use Common;
use NAS::VNX;
##############################################################################
#global declarations
##############################################################################
use subs qw(prep_email prep_excel send_email);
use subs qw(load_all_gold load_gold_server_param);
use subs qw(load_server_param compare_parms load_param_exceptions);
use subs qw(determine_standby);
use subs qw(chk_session_timeouts chk_password_rules);
use subs qw(chk_ports chk_ssh_ver chk_audit);

use vars qw($vnx $fresh);
use vars qw($VERSION $mail_to @email_rpt @hw_rpt @rpt @error_rpt);
use vars qw(@email_rpt_headers);
use vars qw($verbose $debug $hosts $excel_file);
use vars qw($gld_srv_prm); 
use vars qw(@gold_parm_rpt @gold_rpt_headers);
use vars qw(@parm_headers @parm_rpt %parm_exceptions);
use vars qw(@issues_rpt @issues_rpt_headers);
use vars qw(@settings_rpt @settings_rpt_headers);
use vars qw(@ports_rpt @ports_rpt_headers);
##############################################################################
#process command line
##############################################################################
exit 1 unless GetOptions(
          'v' => \$verbose,
          'f|fresh' => \$fresh,
          'm|mail=s' => \$mail_to,
          'h|host=s' => \@$hosts,
          'd' => \$debug
);
##############################################################################
## load $config_file
##############################################################################
chdir ($FindBin::Bin);
my $com=Common->new;
$com->log_file("$FindBin::Bin/../var/log/$Common::shortname.log");
$com->verbose(1) if ($verbose);
my $config_file="$FindBin::Bin/../etc/$Common::shortname.conf";
my %configs=read_config($config_file);
my %vnx_confs=read_config('../etc/vnx.conf');
$configs{shared_conf}= $configs{shared_conf} or die "shared_conf required in $config_file $!";
my %shared_confs=read_config($configs{shared_conf});
%shared_confs=over_rides(\%configs,\%shared_confs);
%shared_confs=over_rides(\%vnx_confs,\%shared_confs);
$shared_confs{email_to}=$mail_to if ($mail_to);
############################################################################
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$mon++;
my $YEAR=substr($year,1);
my $DATE=sprintf("%02d%02d%02d",$mon,$mday,$YEAR);
$hosts=hosts($shared_confs{hosts_file}) unless (@$hosts);
#@$hosts=('ppkvnx02');
##############################################################################
## MAIN
##############################################################################
$com->services;
load_param_exceptions;
load_all_gold;
foreach my $curr_host (@$hosts){
   $com->add_to_log("INFO ".curr_date_time." host=>$curr_host");
   $shared_confs{host}=$curr_host;
   undef $vnx;
   $vnx=VNX->new(\%shared_confs);
   $vnx->verbose(1) if $verbose;
   $vnx->fresh_val(0) if $fresh;
   next if $com->chk_err($vnx,$vnx->chk_host_connect);
   next if ($vnx->q_nas_version =~ m/^[5]/);
   next unless chk_ssh_ver;
   chk_ports;
   my $standby=determine_standby;#determine standby server
   #my $srv_parms=load_server_param($standby); 
   my $srv_parms=$vnx->q_server_param;
   chk_password_rules;
   compare_parms($srv_parms);
   chk_session_timeouts;
   chk_audit;
}#end foreach hosts
#print Dumper(@settings_rpt);
#print Dumper(@issues_rpt);
push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
@settings_rpt_headers=('VNX ','Data Mover ','QA Check ','VNX Value ','Gold Value');
@issues_rpt_headers=('VNX ','QA Issues detected:');
@email_rpt_headers=('VNX','data mover','facility','parameter','gold value','current value');

my $rpt_object=Rpt->new(\%shared_confs);
prep_excel;
my $bdir=$rpt_object->daily_rpt_dir;
$rpt_object->daily_rpt_dir("$bdir/$Common::shortname");
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
#############################################################################
sub chk_audit{
#############################################################################
    if ($vnx->q_nas_version =~ m/^[5]/){
        $com->log("Skipping chk_audit for ".$vnx->host." because DART 5");
        return;
    }
    my $it = $vnx->get_file_cmd('inittab');
    return if $com->chk_err($vnx,$it);
    my $ms = ".AUDIT_ms_bs";
    my $cmd_bs = ".AUDIT_cmd_bs";
    my $cmd_err_bs = ".AUDIT_cmd_err_bs";
    my $secure_bs = ".AUDIT_secure_bs";
    my $VNX_ms = ".AUDIT_ms_bs does not exist in inittab";
    my $VNX_cmd_bs = ".AUDIT_cmd_bs does not exist in inittab";
    my $VNX_cmd_err_bs = ".AUDIT_cmd_err_bs does not exist in inittab";
    my $VNX_secure_bs = ".AUDIT_secure_bs does not exist in inittab";
    #print Dumper($it);
    foreach (@$it){
         next if (/^\s*#/);
         next if (/^\s*$/);
         #say $_;
         if (/$ms/){
             $VNX_ms = "$ms exists in inittab";
             next;
         }
         if (/$cmd_bs/){
             $VNX_cmd_bs= "$cmd_bs exists in inittab";
             next;
         }
         if (/$cmd_err_bs/){
             $VNX_cmd_err_bs= "$cmd_err_bs exists in inittab";
             next;
         }
         if (/$secure_bs/){
             $VNX_secure_bs= "$secure_bs exists in inittab";
             next;
         }
    }
    foreach my $i ('ms','cmd_bs','cmd_err_bs','secure_bs'){
         push @settings_rpt,[
                            $vnx->host,
                            'CS',
                            ".AUDIT_$i exists in inittab",
                            eval('$VNX_'.$i),
                            eval('$'.$i).' exists in inittab'
                            ];
         if (eval('$VNX_'.$i) =~ "does not"){
                push @issues_rpt,[$vnx->host,
                                 eval('$VNX_'.$i)
                                 ];
            }
    }
    #print Dumper(@settings_rpt);
    #exit;

}
#############################################################################
sub chk_ssh_ver{
#############################################################################
  return 2 unless ($shared_confs{ssh_version});
  my ($socket,$client_socket);
  $socket = IO::Socket::INET->new(
            PeerHost => $vnx->host,
            PeerPort => '22',
            Proto => 'tcp') ;
  unless ($socket) {
        $com->add_to_log("ERROR checking ssh port 22 on ".$vnx->host);
        push @error_rpt,[$vnx->host,'ERROR checking ssh port 22'];
        return undef;
  }
  #$socket = IO::Socket::INET->new (
  $com->add_to_log("INFO TCP port 22 Connection Success on ".$vnx->host);

  # read the socket data sent by server.
  my $data = <$socket>;
  chomp $data;
  $socket->close;
  #print "Received from Server : $data\n";
  my $cur_ver = $1 if ($data =~ /SSH-(\d)/i);
  return undef unless $cur_ver;
  unless ($cur_ver eq $shared_confs{ssh_version}){
    push @issues_rpt,[$vnx->host,"host SSH version $cur_ver differs from gold ".$shared_confs{ssh_version}];
  }
   push @settings_rpt,[
                     $vnx->host,
                     'CS',
                     'ssh version',
                     $cur_ver,
                     $shared_confs{ssh_version}||' '
                    ];

}
#############################################################################
sub chk_ports{
#############################################################################
  return undef unless ($shared_confs{disallowed_ports});
  @ports_rpt_headers = ('VNX','Service','Port Number','State');
  $com->add_to_log("INFO checking for dissallowed open ports on ".$vnx->host);

my %port_hash;# = ( tcp => {} );
for my $port (split /\s+/,$shared_confs{disallowed_ports}) {
  $port_hash{'tcp'}{$port} = {};
}
my $timeout = 5;
my $host_hr = check_ports($vnx->host,$timeout,\%port_hash);
#print Dumper($host_hr);exit;
    for my $port (sort {$a <=> $b} keys %{$host_hr->{tcp}}) {
        if ( $host_hr->{tcp}{$port}{open}){
           $com->add_to_log("INFO Disallowed TCP port $port detected open") if $verbose;
           push @issues_rpt,[$vnx->host,"Disallowed TCP port $port detected open"];
           push @ports_rpt,[$vnx->host,${$com->services}{$port}||' ',$port,'Open'];
        } else {
           push @ports_rpt,[$vnx->host,${$com->services}{$port}||' ',$port,'Closed'];
        }
    }
}
#############################################################################
sub chk_password_rules{
#############################################################################
   my ($h_lcredit,$h_dcredit,$h_minlen,
       $h_difok,$h_retry,$h_ucredit,$h_ocredit);
   my $file='/etc/pam.d/system-auth';
   my ($just_file,$path,$suffix) = fileparse($file);
   unless ($vnx->host_file_fresh($just_file)){
     my $target_file=$vnx->host_dir.'/'."$just_file.txt";
     $vnx->scp_get_cmd($file,$target_file);
   }
 
   my ($stdout,$stderr)=$vnx->read_host_file($just_file);
   return undef if ($com->chk_err($vnx,join "\n",@$stdout));
   foreach (@$stdout){
     next if /^#/;
     next unless (/\S/);
     next unless /pam_cracklib.so/;
     #say $_;
     $h_lcredit=$1 if (/lcredit=(\S+)/);
     $h_dcredit=$1 if (/dcredit=(\S+)/);
     $h_minlen=$1  if (/minlen=(\S+)/);
     $h_difok=$1   if (/difok=(\S+)/);
     $h_retry=$1   if (/retry=(\S+)/);
     $h_ucredit=$1 if (/ucredit=(\S+)/);
     $h_ocredit=$1 if (/ocredit=(\S+)/);
   }
   my $host_settings="lcredit=$h_lcredit dcredit=$h_dcredit minlen=$h_minlen difok=$h_difok retry=$h_retry ucredit=$h_ucredit ocredit=$h_ocredit";
   my $gold_settings=' ';
   my @pass_issues;
   if ($shared_confs{passwd_lcredit}){
      $gold_settings.=" lcredit=$shared_confs{passwd_lcredit}";
      unless (lc $shared_confs{passwd_lcredit} eq lc $h_lcredit){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib lcredit $h_lcredit differs from gold $shared_confs{passwd_lcredit}"];
      }
   }
   if ($shared_confs{passwd_dcredit}){
      $gold_settings.=" dcredit=$shared_confs{passwd_dcredit}";
      unless (lc $shared_confs{passwd_dcredit} eq lc $h_dcredit){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib dcredit $h_dcredit differs from gold $shared_confs{passwd_dcredit}"];
      }
   }
   if ($shared_confs{passwd_minlen}){
      $gold_settings.=" minlen=$shared_confs{passwd_minlen}";
      unless (lc $shared_confs{passwd_minlen} eq lc $h_minlen){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib minlen $h_minlen differs from gold $shared_confs{passwd_minlen}"];
      }
   }
   if ($shared_confs{passwd_difok}){
      $gold_settings.=" difok=$shared_confs{passwd_difok}";
      unless (lc $shared_confs{passwd_difok} eq lc $h_difok){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib difok $h_difok differs from gold $shared_confs{passwd_difok}"];
      }
   }
   if ($shared_confs{passwd_retry}){
      $gold_settings.="  retry=$shared_confs{passwd_retry}";
      unless (lc $shared_confs{passwd_retry} eq lc $h_retry){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib retry $h_retry differs from gold $shared_confs{passwd_retry}"];
      }
   }
   if ($shared_confs{passwd_ucredit}){
      $gold_settings.=" ucredit=$shared_confs{passwd_ucredit}";
      unless (lc $shared_confs{passwd_ucredit} eq lc $h_ucredit){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib ucredit $h_ucredit differs from gold $shared_confs{passwd_ucredit}"];
      }
   }
   if ($shared_confs{passwd_ocredit}){
      $gold_settings.=" ocredit=$shared_confs{passwd_ocredit}";
      unless (lc $shared_confs{passwd_ocredit} eq lc $h_ocredit){
        push @issues_rpt,[$vnx->host,"/etc/pam.d/system-auth cracklib ocredit $h_ocredit differs from gold $shared_confs{passwd_ocredit}"];
      }
   }
   $com->add_to_log("INFO system_auth cracklib gold settings: $gold_settings") if ($gold_settings);
   $com->add_to_log("INFO system_auth cracklib host settings: $host_settings") if ($host_settings);
   push @settings_rpt,[
                     $vnx->host,
                     'CS',
                     '/etc/pam.d/system-auth pam_cracklib',
                     $host_settings,
                     $gold_settings||' '
                    ];
}
#############################################################################
sub chk_session_timeouts{
#############################################################################
#check nas_config and nas_cs for session timeout values
 #print "$shared_confs{chk_nas_cs_session_idle_timeout}\n";
 #print "$shared_confs{chk_nas_config_sessiontimeout}\n";
 #print Dumper(${$vnx->q_nas_cs}{'Session Idle Timeout'});
 #print Dumper($vnx->q_nas_config);
 my $nas_config_idle=${$vnx->q_nas_config}{nas_config_sessiontimeout}||'-';
 $nas_config_idle= $1 if ($nas_config_idle =~ /(\d+)\s(\w+)$/);
 $nas_config_idle= 'disabled' if ($nas_config_idle =~ /disabled$/);
 my $cs_idle=${$vnx->q_nas_cs}{'Session Idle Timeout'}||'-';
 $cs_idle=~ s/\s+\w+//;
 
 push @settings_rpt,[
                     $vnx->host,
                     'CS',
                     'nas_cs Session Idle Timeout',
                     $cs_idle,
                     $shared_confs{gold_nas_cs_session_idle_timeout}|| ' '
                    ];
 push @settings_rpt,[
                     $vnx->host,
                     'CS',
                     'nas_config sessiontimeout',
                     $nas_config_idle,
                     $shared_confs{gold_nas_config_sessiontimeout}||' '
                    ];
unless ( $cs_idle eq $shared_confs{gold_nas_cs_session_idle_timeout} ) {
   push @issues_rpt,[
                     $vnx->host,
                     "nas_cs Session Idle Timeout $cs_idle differs from Gold $shared_confs{gold_nas_cs_session_idle_timeout}",
                    ];
}
unless ( $nas_config_idle eq $shared_confs{gold_nas_config_sessiontimeout} ) {
   push @issues_rpt,[
                     $vnx->host,
                     "nas_config sessiontimeout $nas_config_idle differs from Gold $shared_confs{gold_nas_config_sessiontimeout}",
                    ];
}
}
#############################################################################
sub consider{
#############################################################################
  #consider($srv,$fac,$parm,'current',$$srv_parms{$srv}{$fac}{$parm}{current});
   my $srv=shift;
   my $fac=shift;
   my $parm=shift;
   my $key=shift;
   my $val=shift;
   return if ($parm_exceptions{$parm});#if param exception exists
     #print "srv=>$srv fac=>$fac parm=>$parm key=>$key value=>$val\n";
     unless ($$gld_srv_prm{$fac}{$parm}) {
           return undef;
     }
   unless ($val eq $$gld_srv_prm{$fac}{$parm}{$key}){
     #print "DIFFERENCE srv=>$srv fac=>$fac parm=>$parm key=>$key value=>$val GOLDEN VAL=> ";
     my $gld_val;
     if (defined $$gld_srv_prm{$fac}{$parm}{$key}){
         $gld_val=$$gld_srv_prm{$fac}{$parm}{$key};
         #print $$gld_srv_prm{$fac}{$parm}{$key} 
     }else{$gld_val=' '}
     #print "\n";

     push @email_rpt,[
                    $vnx->host,
                    $srv,
                    $fac,
                    $parm,
                    $gld_val,
                    $val,
     ];
     return 1; ##means param difference between gold->current
   }#unless
   return undef;
}
###############################################################################
sub compare_parms{
###############################################################################
  my $srv_parms=shift;
  say "Comparing parms" if $verbose;
  my @pline;#push line
  @parm_headers=('VNX-dm','Facility','Parameter','Default  ','Current  ','Configured  ');
  foreach my $srv (sort keys %$srv_parms){
     my $issue_flag;
     foreach my $fac (keys %{$$srv_parms{$srv}}){
        foreach my $parm (keys %{$$srv_parms{$srv}{$fac}}){
            push @pline,$vnx->host." $srv";
            push @pline,$fac;
            push @pline,$parm;
            #print "$_ " foreach (keys %{$$srv_parms{$srv}{$fac}{$parm}});
            if (defined $$srv_parms{$srv}{$fac}{$parm}{default}){
              #print $$srv_parms{$srv}{$fac}{$parm}{default}.' ';
              push @pline,$$srv_parms{$srv}{$fac}{$parm}{default};
            }else{push @pline,' '}
            if (defined $$srv_parms{$srv}{$fac}{$parm}{current}){
              #print $$srv_parms{$srv}{$fac}{$parm}{current}.' ';
              push @pline,$$srv_parms{$srv}{$fac}{$parm}{current};
              my $ret=consider($srv,$fac,$parm,'current',$$srv_parms{$srv}{$fac}{$parm}{current});
              $issue_flag=1 if ($ret);
            }else{push @pline,' '}
            if (defined $$srv_parms{$srv}{$fac}{$parm}{configured}){
              #print $$srv_parms{$srv}{$fac}{$parm}{configured}.' ';
              push @pline,$$srv_parms{$srv}{$fac}{$parm}{configured};
            }else{push @pline,' '}
            #print "\n";
            push @parm_rpt,[@pline];
            @pline=();undef @pline;
        }#foreach my $parm
     }#foreach my $fac
     if ($issue_flag){
       push @issues_rpt,[$vnx->host,"$srv server_param difference detected"];
     }
  }#forach my $srv
}
###############################################################################
sub load_server_param{
###############################################################################
   my $standby=shift;
   say "loading server param" if $verbose;
   my (%parms,%srv_parms);
   my $chost=$vnx->host;
   my $stdout=$vnx->server_param;
   return undef unless ($stdout);
   @$stdout = reverse @$stdout;
   foreach (@$stdout){
     next unless /\S+/;
     next if (/^param_name/);
     #print "$_\n";
     if (/^(server_\d+)\s+:/){
         $srv_parms{$1}={%parms} unless ($$standby{$1});
         #say "SERVER-> $1";
         %parms=();undef %parms;
         next;
     }
     if (/^global_params:/){
         $srv_parms{global}={%parms};;
         #say "GLOBAL-> global";
         %parms=();undef %parms;
         next;
     }
     my @line=split /\s+/,$_;
     if (scalar @line > 3 ){
       #say "server line";
       $parms{$line[1]}{$line[0]}{default}=$line[2];
       $parms{$line[1]}{$line[0]}{current}=$line[3];
       if (defined $line[4]){
         $parms{$line[1]}{$line[0]}{configured}=$line[4];
       }else{
         $parms{$line[1]}{$line[0]}{configured}= ' ';
       }

     }else{
       $parms{$line[1]}{$line[0]}{default}=$line[2] if (scalar @line == 3);
       #say "set 3" if (scalar @line == 3);
       if (scalar @line == 2){
          #say "set 2";
          if (/^(\S+)cifs\s+(\d+)/){
             #print "CIFS parm $1 $2\n";
             $parms{cifs}{$1}{configured}=$2;
             next;
          }
          if (/^(\S+)NDMP\s+(\d+)/){
             #print "NDMP parm $1 $2\n";
             $parms{NDMP}{$1}{configured}=$2;
             next;
          }
          $parms{$line[1]}{$line[0]}{default}=' ';
       }#end if scalar @line==2
     }#end else
   }#end foreach stdout
   return undef unless %srv_parms;
   print Dumper(%srv_parms) if $debug;
   return \%srv_parms;
}
###############################################################################
sub load_gold_server_param{
###############################################################################
   my $file=$configs{gold_dir}.'/'.$configs{gold_server_param};
   my %parms;
   @gold_rpt_headers=('type','facility','parameter','default   ','current','configured');
   say "loading golden server param -> $file" if $verbose;
   open GOLD,"$file"
       or die "Unable to open $file $!\n";
   my @in_file=(<GOLD>);
   close GOLD;
   chomp @in_file;
   my @pline;#push line;
   foreach (@in_file){
     next unless /\S+/;
     next if (/^param_name/);
     next if (/^server_\d+/);
     return \%parms if (/^global_params:/);
     print "$_\n" if $debug;
     my @line=split /\s+/,$_;
     @pline=();undef @pline;
     push @pline,"server";
     if (defined $line[1]){push @pline,$line[1]}else{push @pline,' '}
     if (defined $line[0]){push @pline,$line[0]}else{push @pline,' '}
     if (defined $line[2]){push @pline,$line[2]}else{push @pline,' '}
     if (defined $line[3]){push @pline,$line[3]}else{push @pline,' '}
     if (defined $line[4]){push @pline,$line[4]}else{push @pline,' '}

     push @gold_parm_rpt,[@pline];
     #push @gold_parm_rpt,['server',$line[1],$line[0],$line[2],$line[3],$line[4]];
     $parms{$line[1]}{$line[0]}{default}=$line[2];
     $parms{$line[1]}{$line[0]}{current}=$line[3];
     $parms{$line[1]}{$line[0]}{configured}=$line[4] || ' ';
     if (defined $line[4]){
         $parms{$line[1]}{$line[0]}{configured}=$line[4];
     }else{
         $parms{$line[1]}{$line[0]}{configured}= ' ';
     }
   }#end foreach @in_file
   return undef unless %parms;
   print Dumper(%parms) if $debug;
   return \%parms;
}
###############################################################################
sub load_all_gold{
###############################################################################
  $gld_srv_prm=load_gold_server_param;
}
###############################################################################
sub load_param_exceptions{
###############################################################################
#load exceptions for server parameters
#gold_exceptions_param
  my $file=$configs{gold_dir}.'/'.$configs{gold_exceptions_param};
  unless (-f $file){
    say "param exceptions file $file does not exist";
    return undef;
  }
  open GOLD,"$file"
     or die "Unable to open $file $!\n";
  my @in_file=(<GOLD>);
  close GOLD;
  chomp @in_file;
  foreach (@in_file){
    #print "$_\n";
    $parm_exceptions{$_}=1;
  }
}
###############################################################################
sub determine_standby{
###############################################################################
  #determines standby datamovers,note there can be more then 1
  #returns hash with standby servers as key, with values as 1
  my %standbys;
  my $stdout=$vnx->q_nas_server;
  foreach  my $srv (keys %$stdout){
    $standbys{$srv}=1 if ($$stdout{$srv}{Type}=~/standby/);
  }
  return undef unless (%standbys);
  return \%standbys;
}
###############################################################################
sub prep_email{
###############################################################################
   my @eheaders;
   $rpt_object->MakeEmailBodyHeaders('Quality Assurance Checks','',\@eheaders);
   $rpt_object->MakeEmailStatusHeaders('Red',\@issues_rpt_headers) if @issues_rpt;
   $rpt_object->MakeEmailBody(\@issues_rpt_headers,\@issues_rpt) if @issues_rpt;
   @parm_headers=('All QA checks pass');
   $rpt_object->MakeEmailStatusHeaders('Green',\@parm_headers) unless (@issues_rpt);
   if (@error_rpt){
      my @title; my @err_headers=('VNX','Error Message');
      push @title,"Errors detected during report:";
      $rpt_object->MakeEmailStatusHeaders('Red',\@title);
      $rpt_object->MakeEmailBody(\@err_headers,\@error_rpt);
      $rpt_object->email("<BR>&nbsp;<BR>\n");
   }
   my @footers;
   push @footers,"$Common::basename ver $VERSION";
   $rpt_object->MakeEmailFooter(\@footers);
   return 1;
}
###########################################################################
sub prep_excel{
###########################################################################
   $excel_file="../tmp/$Common::shortname.xlsx";
   $com->add_to_log("INFO making excel $excel_file") if $verbose;
   #print Dumper(@ports_rpt);
   #print Dumper(@ports_rpt_headers);
   #exit;
   return undef unless (@parm_rpt);
   my %formats;
   $formats{'all'}{3}{'width'}=20.5;
   $rpt_object->excel_file($excel_file);
   $rpt_object->excel_tabs('issues_rpt',\@issues_rpt_headers,\@issues_rpt,1) if @issues_rpt;
   $rpt_object->excel_tabs('services_rpt',\@ports_rpt_headers,\@ports_rpt,1) if @ports_rpt;
   $rpt_object->excel_tabs('settings_rpt',\@settings_rpt_headers,\@settings_rpt,2) if @settings_rpt;
   $rpt_object->excel_tabs('server_params_rpt',\@parm_headers,\@parm_rpt,1) if @parm_rpt;
   $rpt_object->excel_tabs('gold_server_params',\@gold_rpt_headers,\@gold_parm_rpt,1) if @gold_parm_rpt;
   $rpt_object->excel_tabs('param_differences_from_gold',\@email_rpt_headers,\@email_rpt,1) if @email_rpt;
   $rpt_object->write_excel_tabs if ($rpt_object->excel_tabs);
}
###########################################################################
sub send_email{
###########################################################################
   return unless ($rpt_object->email_to);
   $rpt_object->email_subject("$configs{email_subject} ".curr_date_time) if ($configs{email_subject});
   $com->add_to_log("INFO sending email to ".$rpt_object->email_to);
   $rpt_object->email_attachment($excel_file) if (-f $excel_file);
   $rpt_object->SendEmail;# unless ($mail_to eq 'none')
}
