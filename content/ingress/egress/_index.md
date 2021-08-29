---
title: "Egress"
date: 2020-09-13T17:33:04+01:00
weight: 70
summary: "Ingress proxy routing"
---

```
make egress-setup
```


```
$ kubectl -n default get pod -l name=net-tshoot -o name | xargs -I{} kubectl exec {} -- wget -q -O - echo
```

 
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumEgressNATPolicy
metadata:
  name: egress-all
spec:
  destinationCIDRs:
  - 172.18.0.0/16
  egress:
  - podSelector:
      matchLabels:
        io.kubernetes.pod.namespace: default
  egressSourceIP: 172.18.0.5
```

```
$ kubectl get pod -owide
NAME               READY   STATUS    RESTARTS   AGE     IP           NODE                      NOMINATED NODE   READINESS GATES
net-tshoot-5ngbc   1/1     Running   0          4h53m   10.0.0.174   k8s-guide-control-plane   <none>           <none>
net-tshoot-gcj27   1/1     Running   0          4h53m   10.0.2.86    k8s-guide-worker2         <none>           <none>
net-tshoot-pcgf8   1/1     Running   0          4h53m   10.0.1.42    k8s-guide-worker          <none>           <none>
```


```
$ NODE=k8s-guide-worker2
$ cilium=$(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
$ kubectl -n cilium exec -it $cilium -- bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_egress_v4
key: 30 00 00 00 0a 00 00 ae  ac 12 00 00  value: ac 12 00 05 ac 12 00 05
key: 30 00 00 00 0a 00 01 2a  ac 12 00 00  value: ac 12 00 05 ac 12 00 05
key: 30 00 00 00 0a 00 02 56  ac 12 00 00  value: ac 12 00 05 ac 12 00 05
```



`handle_ipv4_from_lxc` in bpf_lxc.c

 ```c
 #ifdef ENABLE_EGRESS_GATEWAY
	{
		struct egress_info *info;
		struct endpoint_key key = {};

		info = lookup_ip4_egress_endpoint(ip4->saddr, ip4->daddr);
		if (!info)
			goto skip_egress_gateway;

		/* Encap and redirect the packet to egress gateway node through a tunnel.
		 * Even if the tunnel endpoint is on the same host, follow the same data
		 * path to be consistent. In future, it can be optimized by directly
		 * direct to external interface.
		 */
		ret = encap_and_redirect_lxc(ctx, info->tunnel_endpoint, encrypt_key,
					     &key, SECLABEL, monitor);
		if (ret == IPSEC_ENDPOINT)
			goto encrypt_to_stack;
		else
			return ret;
	}
skip_egress_gateway:
#endif
```

`handle_ipv4` in bpf_overlay.c

```
	/* Lookup IPv4 address in list of local endpoints */
	ep = lookup_ip4_endpoint(ip4);
	if (ep) {
		/* Let through packets to the node-ip so they are processed by
		 * the local ip stack.
		 */
		if (ep->flags & ENDPOINT_F_HOST)
			goto to_host;

		return ipv4_local_delivery(ctx, ETH_HLEN, *identity, ip4, ep,
					   METRIC_INGRESS, false);
	}
```


```
$ bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_lxc
 key:
ac 12 00 03 00 00 00 00  00 00 00 00 00 00 00 00
01 00 00 00
value:
00 00 00 00 00 00 00 00  01 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
```

```c

	/* A packet entering the node from the tunnel and not going to a local
	 * endpoint has to be going to the local host.
	 */
to_host:
#ifdef HOST_IFINDEX
	if (1) {
		union macaddr host_mac = HOST_IFINDEX_MAC;
		union macaddr router_mac = NODE_MAC;
		int ret;

		ret = ipv4_l3(ctx, ETH_HLEN, (__u8 *)&router_mac.addr,
			      (__u8 *)&host_mac.addr, ip4);
		if (ret != CTX_ACT_OK)
			return ret;

		cilium_dbg_capture(ctx, DBG_CAPTURE_DELIVERY, HOST_IFINDEX);
		return redirect(HOST_IFINDEX, 0);
	}
#else
	return CTX_ACT_OK;
#endif
```

`from-host` in bpf_host.c


```
cilium map get cilium_ipcache  | grep "0.0.0.0/0"
0.0.0.0/0       2 0 0.0.0.0          sync
```

`do_netdev` in bpf_host.c -> `tail_handle_ipv4_from_host` -> `tail_handle_ipv4` -> `handle_ipv4` -> fall through to local stack

`to-host` in bpf_host.c (eth0) -> `handle_nat_fwd` -> `tail_handle_nat_fwd_ipv4` -> `nodeport_nat_ipv4_fwd`

```c
#if defined(ENABLE_NODEPORT) && \
	(!defined(ENABLE_DSR) || \
	 (defined(ENABLE_DSR) && defined(ENABLE_DSR_HYBRID)) || \
	 defined(ENABLE_MASQUERADE) || \
	 defined(ENABLE_EGRESS_GATEWAY))
	if ((ctx->mark & MARK_MAGIC_SNAT_DONE) != MARK_MAGIC_SNAT_DONE) {
		ret = handle_nat_fwd(ctx);
		if (IS_ERR(ret))
			return send_drop_notify_error(ctx, 0, ret,
						      CTX_ACT_DROP,
						      METRIC_EGRESS);
	}
#endif
```

`snat_v4_process` in bpf/lib/nat.h -> `snat_v4_handle_mapping` -> `snat_v4_new_mapping`

```c
#pragma unroll
	for (retries = 0; retries < SNAT_COLLISION_RETRIES; retries++) {
		if (!snat_v4_lookup(&rtuple)) {
			ostate->common.created = bpf_mono_now();
			rstate.common.created = ostate->common.created;

			ret = snat_v4_update(otuple, ostate, &rtuple, &rstate);
			if (!ret)
				break;
		}

		port = __snat_clamp_port_range(target->min_port,
					       target->max_port,
					       retries ? port + 1 :
					       get_prandom_u32());
		rtuple.dport = ostate->to_sport = bpf_htons(port);
	}
```