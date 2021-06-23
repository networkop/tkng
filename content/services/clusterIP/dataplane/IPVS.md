---
title: "IPVS"
date: 2020-09-13T17:33:04+01:00
weight: 20
---


https://www.projectcalico.org/comparing-kube-proxy-modes-iptables-or-ipvs/


This is one thing to remember when migrating from iptables to ipvs on an existing cluster, instead of rebuilding it from scratch, is that all of the KUBE-SEP chains will still be there and may need to be cleaned up either manually or via Node reboot.