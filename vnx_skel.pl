#!/usr/bin/perl -w
###########################################################################
## vnx_skel.pl
## Written by Michael Denney (michael.s.denney@gmail.com)
## VNX skeleton for developing new scripts
my $VERSION=1.11;
###########################################################################
##HISTORY
##1.0  Initial
##1.1  vnx.conf
##1.11 -m fix
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

use subs qw(prep_email prep_excel send_email chk_err prep_rpt);
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
#@hosts=('ppkvfs100');
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
   next if chk_err(($vnx->chk_host_connect));
   ##Subs to load data normally goes here
   ## HEre is a line to populate some data into @email_rpt
   push @email_rpt,[$vnx->host,'Some data here','more data here'];
}
prep_rpt;

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
sub chk_err{
###############################################################################
   my $chk_val=shift;
   if ($vnx->errlog){
      $com->add_to_log("ERROR DETECTED");
      push @error_rpt,@{$vnx->errlog};
      if ($vnx->log){
         foreach my $txt (@{$vnx->log}){
           $com->add_to_log($txt);
         }
      }
      $vnx->clear_errlog;
      return 1;
   }
   unless ($chk_val){
      foreach my $txt (@{$vnx->log}){
        $com->add_to_log($txt);
      }
      $vnx->clear_log;
     return 1 
   }
   return undef;
}
###############################################################################
sub location{
###############################################################################
  my $host=shift or return undef;
  return 'Groton' if ($host=~/^\S+\.gro/i or $host=~/^gro/i);
  return 'Peapack' if ($host=~/^ppk/i or $host=~/^\S+\.ppk/i);
  return 'Cambridge' if ($host=~/^\S+\.cmg/i or $host=~/^cmg/i);
  return ' ';
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
   my @eheaders;
   push @eheaders,"<a href=\"$shared_confs{cifs_daily_rpt_dir}\\$Common::shortname\\$excel_target\">Spreadsheet Rpt</a>";
   $rpt_object->MakeEmailBodyHeaders('','',\@eheaders);
   if (@error_rpt){
      my @title; my @err_headers=('VNX','Error Message');
      push @title,"Errors detected during report:";
      $rpt_object->MakeEmailStatusHeaders('Red',\@title);
      $rpt_object->MakeEmailBody(\@err_headers,\@error_rpt);
      $rpt_object->email("<BR>&nbsp;<BR>\n");
   }
   $rpt_object->MakeEmailBody(\@email_rpt_headers,\@email_rpt) if (@email_rpt_headers and @email_rpt);
   $rpt_object->email("<BR>&nbsp;<BR>\n");#blank line if more table reports
   
   my @footers;
   push @footers,'Footer text goes here';
   push @footers,' ';
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
   $rpt_object->excel_tabs('Email Rpt Tab Here',\@email_rpt_headers,\@email_rpt,1) if @email_rpt;
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
