---
title: "IPVS"
date: 2020-09-13T17:33:04+01:00
weight: 20
---


https://www.projectcalico.org/comparing-kube-proxy-modes-iptables-or-ipvs/

https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/

https://github.com/kubernetes/enhancements/tree/0e4d5df19d396511fe41ed0860b0ab9b96f46a2d/keps/sig-network/265-ipvs-based-load-balancing

https://docs.google.com/presentation/d/1BaIAywY2qqeHtyGZtlyAp89JIZs59MZLKcFLxKE6LyM/edit

scheduler
https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/#parameter-changes


### Lab Setup

Assuming that the lab environment is already [set up](/lab/), ipvs can be enabled with the following commands:

```bash
make ipvs
```

The above command updates `kube-proxy`'s ConfigMap so in order for this change to be picked up, we need to restart all of the agents and flush out any existing iptable rules:

```bash
make flush-nat
```

A good way to verify that the change has suceeded is to check that all Nodes now have a new ipvs device and a much smaller iptables size:

```bash
$ docker exec -it k8s-guide-worker ip link show kube-ipvs0 
7: kube-ipvs0: <BROADCAST,NOARP> mtu 1500 qdisc noop state DOWN mode DEFAULT group default
    link/ether 22:76:01:f0:71:9f brd ff:ff:ff:ff:ff:ff

$ docker exec -it k8s-guide-worker iptables -t nat -nvL KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
```


{{% notice note %}}
One thing to remember when migrating from iptables to ipvs on an existing cluster (as opposed to rebuilding it from scratch), is that all of the KUBE-SVC/KUBE-SEP chains will still be there and may need to be cleaned up either manually or via Node reboot.
{{% /notice %}}


```bash
$ kubectl create deploy web --image=nginx --replicas=2
$ kubectl expose deploy web --port 80
```


```
$ kubectl get deploy web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    2/2     2            2           90s
$ kubectl get svc web
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.119.228   <none>        80/TCP    92s
```


```
docker exec k8s-guide-worker apt install ipset ipvsadm -y
```

```bash
$ alias ipt="docker exec k8s-guide-worker iptables -t nat -nvL"
$ alias ipv="docker exec k8s-guide-worker ipvsadm -ln"
$ alias ips="docker exec k8s-guide-worker ipset list"
```


```
$  ipt PREROUTING
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
  128 12020 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
    0     0 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1

```
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
```

```
$ ipt KUBE-NODE-PORT 
Chain KUBE-NODE-PORT (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Kubernetes nodeport TCP port for masquerade purpose */ match-set KUBE-NODE-PORT-TCP dst
```

```
$ ips KUBE-CLUSTER-IP
Name: KUBE-CLUSTER-IP
Type: hash:ip,port
Revision: 5
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 768
References: 2
Number of entries: 9
Members:
10.96.0.10,udp:53
10.96.0.1,tcp:443
10.96.0.10,tcp:53
10.96.148.225,tcp:80
10.96.68.46,tcp:3030
10.96.10.207,tcp:3030
10.96.0.10,tcp:9153
10.96.159.35,tcp:11211
10.96.119.228,tcp:80
```


```
$ ipv
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  192.168.224.4:31730 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  10.96.0.1:443 rr
  -> 192.168.224.3:6443           Masq    1      0          0
TCP  10.96.0.10:53 rr
  -> 10.244.0.3:53                Masq    1      0          0
  -> 10.244.0.4:53                Masq    1      0          0
TCP  10.96.0.10:9153 rr
  -> 10.244.0.3:9153              Masq    1      0          0
  -> 10.244.0.4:9153              Masq    1      0          0
TCP  10.96.10.207:3030 rr
  -> 10.244.1.4:3030              Masq    1      0          0
TCP  10.96.68.46:3030 rr
  -> 10.244.2.2:3030              Masq    1      0          0
TCP  10.96.119.228:80 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  10.96.148.225:80 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  10.96.159.35:11211 rr
  -> 10.244.1.3:11211             Masq    1      0          0
TCP  10.244.2.1:31730 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  127.0.0.1:31730 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
UDP  10.96.0.10:53 rr
  -> 10.244.0.3:53                Masq    1      0          8
  -> 10.244.0.4:53                Masq    1      0          8
```



```
~/k8s-guide-labs master ❯ ipt OUTPUT                                          0.40  5.17G  172.28.143.166 ⇣0.11 KiB/s ⇡0.11 KiB/s
Chain OUTPUT (policy ACCEPT 5 packets, 300 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1062 68221 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
  287 19636 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1
~/k8s-guide-labs master ❯ ipt KUBE-SERVICES                                   0.43  5.17G  172.28.143.166 ⇣4.07 KiB/s ⇡2.05 KiB/s
Another app is currently holding the xtables lock. Perhaps you want to use the -w option?
~/k8s-guide-labs master ❯ ipt KUBE-SERVICES                                   0.44  5.16G  172.28.143.166 ⇣0.61 KiB/s ⇡0.36 KiB/s
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
~/k8s-guide-labs master ❯ ipt KUBE-MARK-MASQ                                  0.43  5.12G  172.28.143.166 ⇣0.33 KiB/s ⇡0.22 KiB/s
Chain KUBE-MARK-MASQ (13 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK or 0x4000
~/k8s-guide-labs master ❯ ipt POSTROUTING                                     0.42  5.16G  172.28.143.166 ⇣0.76 KiB/s ⇡0.42 KiB/s
Chain POSTROUTING (policy ACCEPT 5 packets, 300 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1199 80799 KUBE-POSTROUTING  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes postrouting rules */
    0     0 DOCKER_POSTROUTING  all  --  *      *       0.0.0.0/0            192.168.224.1
  920 61751 KIND-MASQ-AGENT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type !LOCAL /* kind-masq-agent: ensure nat POSTROUTING directs all non-LOCAL destination traffic to our custom KIND-MASQ-AGENT chain */
~/k8s-guide-labs master ❯ ipt KUBE-POSTROUTING                                0.41  5.16G  172.28.143.166 ⇣0.99 KiB/s ⇡0.58 KiB/s
Chain KUBE-POSTROUTING (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Kubernetes endpoints dst ip:port, source ip for solving hairpin purpose */ match-set KUBE-LOOP-BACK dst,dst,src
    1    60 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            mark match ! 0x4000/0x4000
    0     0 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK xor 0x4000
    0     0 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service traffic requiring SNAT */ random-fully
```