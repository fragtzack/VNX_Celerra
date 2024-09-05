#!/usr/local/bin/python3
"""Get and report on NAS servers -> IP
   Create a csv file and a json.
"""
__author__ = "michael.s.denney@gmail.com"
__version__ = "1.2.1"

import sys
import os
import pprint
import logging
import io
import copy 
import re
import shutil
import time
import simplejson as json
import socket

os.chdir(os.path.dirname(os.path.realpath(__file__)))
sys.path.append("../pylib")
import hosts
import rpt
import util
###########################################################################
## GLOBALS
###########################################################################
ipheader = ['IP','Type','Array','DM','VDM']
iptable = rpt.Table(ipheader) 
localre = re.compile(r'^(127|128)\.') ##exclude from all arrays reporting
###########################################################################
def get_vnx_vdm(vnx=None,dev=None):
###########################################################################
    log.info("Geting nas_server for VDM determination, if={} "
            .format(dev))
    ns = vnx.nas_server_type
    if not ns:
        return None
    #pprint.pprint(ns)
    try:
        for vdm,inner in ns['vdm'].items():
            #print(vdm,inner['CifsUsedInterfaces'])
            if re.search(dev,inner['CifsUsedInterfaces']):
                return(vdm)
    except:
        pass
    return(' ')
###########################################################################
def get_vnx(vnx=None):
###########################################################################
    log.info("Geting nas_server_ifconfig")
    ifconfs = vnx.nas_server_ifconfig
    if not ifconfs:
        return None
    #pprint.pprint(ifconfs)
    #sys.exit()
    if not ifconfs:
        return None
    for srv,inner in ifconfs.items():
        #print(srv)
        for dev in inner:
            ip = inner[dev]['Address'] 
            vdm = get_vnx_vdm(vnx,dev)
            if re.search(localre,ip):
                continue
            MAC = inner[dev]['EthernetAddress']
            iptable.IP.append(ip)
            iptable.Type.append('VNX')
            iptable.Array.append(vnx.name)
            iptable.DM.append(srv)
            iptable.VDM.append(vdm)
###########################################################################
def vnx_main():
###########################################################################
    """\nLaunch point for iterating through vnx hosts."""
 
    log.info("Start Vnx loop")
    op=hosts.SetOpts(opts=opts,flavor='vnx')
    for host in sorted(op.hosts):
        util.check_server(host,22)
        if hosts.errors_check(host): continue
        vnx=hosts.Vnx(host) 
        get_vnx(vnx)
        hosts.errors_check(host)
###########################################################################
def expand_ranges(rng=None):
###########################################################################
    """\nTakes a range of IP's in the format: xxx.xxx.xxx.xxx-xxx.xxx.xxx.xxx
         and returns a list single IP's from that range"""

    if not rng:
        return []
    log.debug("Expanding range {}".format(rng))
    start_ip,end_ip=rng.split("-")
    start_ip = start_ip.lstrip()
    end_ip = end_ip.lstrip()
    start = list(map(int, start_ip.split(".")))
    end = list(map(int, end_ip.split(".")))
    temp = start
    ip_range = []
   
    ip_range.append(start_ip)
    while temp != end:
       start[3] += 1
       for i in (3, 2, 1):
          if temp[i] == 256:
             temp[i] = 0
             temp[i-1] += 1
       ip_range.append(".".join(map(str, temp)))    
    return(ip_range)
###########################################################################
def get_isi(isi=None):
###########################################################################
    #ipheader = ['IP','Type','Array','DM','VDM']
    log.info("Geting network_list_pools")
    npools = isi.networks_list_pools
    if not npools:
        self.error("No pool found")
        return None
    for outer,inner in npools.items():
        #print(outer)
        #print(inner['IPranges'])
        accessz = inner['Access Zone']
        ips= []
        for rng in (inner['IPranges']).split():
            #print(rng)
            ips = ips + expand_ranges(rng)
        for ip in ips:
            if re.search(localre,ip):
                continue
            iptable.IP.append(ip)
            iptable.Type.append('Isilon')
            iptable.Array.append(isi.name)
            iptable.DM.append(' ')
            iptable.VDM.append(accessz)
        #for key,val in sorted(inner.items()):
            #print("\"{}\",".format(key),end="")
###########################################################################
def isi_main():
###########################################################################
    """\nLaunch point for iterating through Isilon hosts."""
 
    log.info("Start Isilon loop")
    op=hosts.SetOpts(opts=opts,flavor='isi')
    for host in sorted(op.hosts):
        util.check_server(host,22)
        if hosts.errors_check(host): continue
        isi=hosts.Isilon(host) 
        get_isi(isi)
        hosts.errors_check(host)
###########################################################################
def get_netapp(netapp=None):
###########################################################################
    #ipheader = ['IP','Type','Array','DM','VDM']
    log.info("Getting ifconfig")
    ifconfs = netapp.ifconfig
    if not ifconfs:
        return None
    #pprint.pprint(ifconfs)
    for ip,dev  in ifconfs.items():
        #print(ip,dev)
        if re.search(localre,ip):
            continue
        iptable.IP.append(ip)
        iptable.Type.append('Netapp')
        iptable.Array.append(netapp.name)
        iptable.DM.append(' ')
        iptable.VDM.append(' ')
###########################################################################
def netapp_main():
###########################################################################
    """\nLaunch point for iterating through Netapp hosts."""
 
    log.info("Start Netapp loop")
    op=hosts.SetOpts(opts=opts,flavor='netapp')
    for host in sorted(op.hosts):
        util.check_server(host,22)
        if hosts.errors_check(host): continue
        netapp=hosts.Netapp(host) 
        get_netapp(netapp)
        hosts.errors_check(host)
###########################################################################
def dfs_main():
###########################################################################
    """\nNeed to add IP's of DFS servers also"""
    try:
        opts.dfsroot
    except:
        log.info("dfsroot not specified")
        return False
    ##only consider the raw lines
    rawre = re.compile(r'SocketKind.SOCK_RAW')
    #pprint.pprint(opts.dfsroot)
    #pprint.pprint(socket.getaddrinfo(opts.dfsroot,22))
    for row in socket.getaddrinfo(opts.dfsroot,22):
       #consider = str(row[1])
       if re.search(rawre,str(row[1])):
           #print row
           ip = ((row[4])[0])
           #print(ip)
           iptable.IP.append(ip)
           iptable.Type.append('DFS')
           iptable.Array.append('DFS')
           iptable.DM.append(' ')
           iptable.VDM.append(' ')
    hosts.errors_check(host='DFS')
###########################################################################
def send_rpt():
###########################################################################
    log.info("Creating csv json files")
    myrpt = rpt.Rpt(opts=opts)
    #pprint.pprint(iptable.data)
    #sys.exit()
    iptable.to_csv(myrpt.dailyname)
    iptable.to_csv(myrpt.dailydatename)
    ##now we make a dict for putting into a json
    ipdict = {}
    for row in iptable.data:
         #print(row)
         ip=row[0]
         ipdict[ip]={}
         ipdict[ip]['type']=row[1]
         ipdict[ip]['array']=row[2]
         ipdict[ip]['dm']=row[3]
         ipdict[ip]['vdm']=row[4]
         
    jdump = json.dumps(ipdict,indent=4)
    jfile = myrpt.dailyname + '.json'
    log.info("Dump json file=>{}".format(jfile))
    with open(jfile,'w') as fh:
        print(jdump,file=fh)
    #pprint.pprint(iptable.data)
    #pprint.pprint(ipdict)
###########################################################################
def main():
###########################################################################
    log.info("START")
    global opts
    opts=hosts.SetOpts(opts=argo,main='hosts',script=True)
    log.debug(pprint.pformat(opts.__dict__))
    if not opts.isilon and not opts.vnx:
        netapp_main()
    if not opts.netapp and not opts.vnx:
        isi_main()
    if not opts.netapp and not opts.isilon:
        vnx_main()
    if not opts.netapp and not opts.isilon and not opts.vnx:
        dfs_main()
    hosts.errors_check(host='MAIN')
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
   argo=hosts.ArgParse(description="Report IP Interfaces of NAS arrays.")
   argo.add_argument('--vnx',action='store_true',help="Perform actions only on VNX platforms instead of all platforms")
   argo.add_argument('--netapp',action='store_true',help="Perform actions only on Netapp platforms instead of all platforms")
   argo.add_argument('--isilon',action='store_true',help="Perform actions only on Isilon platforms instead of all platforms")
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
        1.2.0 dfs_main
        1.2.1 Better error checking for dicts containing elements
        1.2.3 Fix for netapp having more then 1 IP per device
        1.3.0 Isilon Access Zones are now specified in vdm column
        1.3.1 Fix for network pools to seperate access zone name and zone id
     """
     pass
