#!/usr/local/bin/python3
"""Colletion for VNX.
"""
__author__ = "michael.s.denney@gmail.com"
__version__ = "1.0.1"

import sys
import os
import pprint
import logging
import io
import copy 
import re
import shutil
import time

os.chdir(os.path.dirname(os.path.realpath(__file__)))
sys.path.append("../pylib")
import hosts
import rpt
import util
###########################################################################
## GLOBALS
###########################################################################
##  ##special commands that are different between dart5 and dart6 +
scmds = ('q_nas_fs','q_server_cifs','nas_server_ifconfig','server_http',
         'nas_cel_interconnect','nas_replicate','nas_fs_ckpt',
         'server_iscsi_lun','server_iscsi_mask','nas_emailuser',
         'server_ftp')
d5cmds = ('dart5_q_nas_fs','dart5_q_server_cifs','dart5_nas_server_ifconfig')
###########################################################################
def collect_cmds(vnx=None,op=None):
###########################################################################
    """\nIterating and collecting all ^command_ from <flavor>.conf."""
    log.info("Collecting from {}".format(vnx.name))
    p = re.compile('^command_(\S+)\s*', re.I)
    for k,v in op.__dict__.items():
        m = p.match(k)
        if not m or not m.group(1):
            continue
        clabel = m.group(1) ##command label
        #if clabel != 'server_df_i':
            #continue
        #print(vnx.name,clabel,vnx.nas_version)
        #sys.exit()
        if clabel in scmds and vnx.nas_version.startswith('5'):
            log.info("Skipping {} cause Dart5 vnx".format(clabel))
            continue
        if  clabel in d5cmds and not vnx.nas_version.startswith('5'):
            log.info("Skipping {} cause Dart5 vnx command".format(clabel))
            continue
        vnx.get_file_cmd(clabel)
###########################################################################
def vnx_main():
###########################################################################
    """\nLaunch point for iterating through vnx hosts."""
 
    log.info("Start VNX loop")
    op=hosts.SetOpts(opts=opts,flavor='vnx')
    for host in sorted(op.hosts):
        util.check_server(host,22)
        if hosts.errors_check(host):
            continue
        vnx=hosts.Vnx(host) 
        collect_cmds(vnx,op)
        hosts.errors_check(host)
###########################################################################
def send_rpt():
###########################################################################
    myrpt = rpt.Rpt(opts=opts)
    
    if hosts.errorrpt:
        myrpt.add_css_heading("Errors with script","Red")
        myrpt.add_css_table(data=hosts.errorrpt,
                            header=["Host","Message"])
    else:
        myrpt.add_css_heading("VNX Collections complete","Green")
        
    m = []
    m.append("""  """)
    m.append(opts.script + " " + __version__)
    myrpt.add_css_footer(m)
    myrpt.send_email()
###########################################################################
def main():
###########################################################################
    log.info("START")
    global opts
    opts=hosts.SetOpts(opts=argo,main='hosts',script=True)
    log.debug(pprint.pformat(opts.__dict__))
    vnx_main()
    hosts.errors_check(host='NA')
    hosts.errors_alert(opts)
    send_rpt()
    log.info("END")

##########################################################################
"""options hash/objects used in script:
     argo = command line args.
     opts = main options from argo and hosts.conf file.
     op   = options from flavor (vnx.conf, netapp.conf, script.conf) 
            combined with opts.
"""
###########################################################################
if __name__ == "__main__":
   argo=hosts.ArgParse(description="VNX collector.")
   argo=argo.parse_args()
   if argo.version : print (__version__) ; sys.exit()
   log = logging.getLogger()
   hosts.config_logging(opt=argo)
   log.debug(pprint.pformat(argo.__dict__))
   main()
   sys.exit(0)
###########################################################################
def history():
###########################################################################
     """\n1.0.1 initial skel
        2.0.0 special_commands, account for dart5
        2.0.1 error_check occurs at end of each host
     """
     pass
