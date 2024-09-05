#!/usr/bin/perl -w
###########################################################################
## vnx_quota_notify.pl
## Written by Michael Denney (michael.s.denney@gmail.com)
## Send capacity notification for a quota to an email address
my $VERSION=1.14;
###########################################################################
##HISTORY
##1.0  Initial
##1.1  vnx.conf
##1.11 -m fix
##1.13 $com->chk_err
##1.14 push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
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

use subs qw(prep_email prep_excel send_email prep_rpt);
use subs qw(determine_alerts get_quota);
###########################################################################
#process command line
###########################################################################
exit 1 unless GetOptions(
          'v' => \$verbose,
          'f|fresh' => \$fresh,
          'm|mail=s' => \$mail_to,
          'h|hosts=s' => \@$hosts,
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
#########################################################################
## MAIN
#########################################################################
my %alerts=determine_alerts;
exit 1 unless (%alerts);
my $rpt_object=Rpt->new(\%shared_confs);
foreach my $uri (keys %alerts){
  get_quota($uri,$alerts{$uri});
}

exit;
###############################################################################
sub get_quota{
###############################################################################
  my $uri=shift or return undef;
  my $quota=shift or return undef;
  my $path=$$quota{path};
  my $fs=$$quota{fs};
  my $emails=$$quota{emails};
  $com->add_to_log("INFO ".curr_date_time." ".host=>$$quota{vnx});
  $shared_confs{host}=$$quota{vnx};
  undef $vnx;
  $vnx=VNX->new(\%shared_confs);
  $vnx->verbose(1) if $verbose;
  $vnx->fresh_val(0) if $fresh;
  return undef if $com->chk_err($vnx,$vnx->chk_host_connect);
  my $trees=$vnx->q_nas_fs_tree_quotas;
  return undef if $com->chk_err($vnx,$$trees{$fs});
  #print Dumper $trees;
  #print "path $path fs $fs\n";
  #print Dumper $$trees{$fs}{$path};
  unless (exists $$trees{$fs}{$path}){
     push @error_rpt,[$vnx->host,"Unable to determine quota for $fs -> $path"];
     return undef;
  }
  my $usage=$$trees{$fs}{$path}{BlockUsage}.' KB';
  my $limit=$$trees{$fs}{$path}{BlockHardLimit}.' KB';
  #$usage=$vnx->to_GB($usage.'k').'GB';
  #$limit=$vnx->to_GB($limit.'k').'GB';
  #print "$fs $path $usage $limit\n";
  return undef unless (defined $usage);
  $rpt_object=Rpt->new(\%shared_confs);
  $rpt_object->email_to($emails);
  push @error_rpt,@Common::error_rpt if (@Common::error_rpt);
  prep_email($$quota{vnx},$uri,$fs,$usage,$limit);
  send_email;

  undef $rpt_object;
  
}
###############################################################################
sub determine_alerts{
###############################################################################
# Parse the script.conf file hash for the user created alerts
  unless (-f $config_file){
    $com->add_to_log("ERROR $config_file not found");
    exit;
  }
  $com->add_to_log("INFO Parsing $config_file");
  unless (open (FH, $config_file)) { 
    $com->add_to_log("ERROR opening config_file $config_file");
    exit 1;
  }
  my %alerts;
  my @file=(<FH>);
  close FH;
  chomp @file;
  foreach (@file){
    next if /^\s*$/;# ignore blank lines
    next if /^#/;   # ignore comments
    s/#.*//;        # remove trailing comments
    s/^\s*//;       # remove leading space
    s/\s*$//;       # remove trailing space
    my $count = ($_ =~ tr/=//);
    next unless ($count == 4);
    my ($vx,$fs,$path,$uri,$emails)=split /=/;
    #print "$_\n";
    $alerts{$uri}{vnx}=$vx;
    $alerts{$uri}{fs}=$fs;
    $alerts{$uri}{path}=$path;
    $alerts{$uri}{emails}=$emails;
  }
  return %alerts;
}
###############################################################################
sub prep_rpt{
###############################################################################
# Final prep of rpt outside main loop and place to declare headders
  @email_rpt_headers=('VNX ','Data col 1','Data col 2');
}
###############################################################################
sub prep_email{
###############################################################################
   my $host=shift;
   my $uri=shift;
   my $fs=shift;
   my $usage=shift;
   my $limit=shift;
   my @eheaders;
   $rpt_object->email_subject("$configs{email_subject} \"$uri\" ".curr_date_time) if ($configs{email_subject});
   push @eheaders,"Served by $host";
   push @eheaders,"Containing file system $fs";
   push @eheaders,"Capacity used $usage";
   push @eheaders,"Quota limit $limit";
   $rpt_object->MakeEmailBodyHeaders('','',\@eheaders);
   if (@error_rpt){
      my @title; my @err_headers=('VNX','Error Message');
      push @title,"Errors detected during report:";
      $rpt_object->MakeEmailStatusHeaders('Red',\@title);
      $rpt_object->MakeEmailBody(\@err_headers,\@error_rpt);
      $rpt_object->email("<BR>&nbsp;<BR>\n");
   }
   $rpt_object->email("<BR>&nbsp;<BR>\n");#blank line if more table reports
   
   my @footers;
   push @footers,' ';
   push @footers,"$Common::basename ver $VERSION";
   $rpt_object->MakeEmailFooter(\@footers);
   return 1;

}
###########################################################################
sub send_email{
###########################################################################
   #print Dumper(@email_rpt_headers);exit;
   $com->add_to_log("INFO sending email to ".$rpt_object->email_to);
   $rpt_object->SendEmail;# unless ($mail_to eq 'none')
}
