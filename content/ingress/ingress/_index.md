---
title: "Ingress API"
date: 2020-09-13T17:33:04+01:00
weight: 10
summary: "Ingress proxy routing"
---

Although technically it is possible to expose internal applications via NodePort or LoadBalancer Services, this happens very rarely. There are two main reasons for that:

* **Costs** -- since each LoadBalancer Services is associated with a single external address, this can translate into a sizeable fee when running in a public cloud environment.
* **Functionality** -- simple L4 load balancing provided by Services lacks a lot of the features that are typically associated with an application proxy or gateway. This means that each exposed application will need to take care of things like TLS management, rate-limiting, authentication and intelligent traffic routing on its own. 

Ingress was designed as a generic, vendor-independent API to configure an HTTP load balancer that would be available to multiple Kubernetes applications. Running an Ingress would amortise the costs and efforts of implementing an application gateway functionality and provide an easy to consume, native Kubernetes experience to cluster operators and users. At the very least, a user is expected to define a single rule telling the Ingress which backend Service to use. This would result in all incoming HTTP requests to be routed to one of the healthy Endpoint of this Service:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example
spec:
  rules:
  - http:
      paths:
      - backend:
          service:
            name: web
            port:
              number: 80
        path: /
```

Similar to Service type [LoadBalancer](/services/loadbalancer/), Kuberenetes only defines the Ingress API and leaves implementation to cluster add-ons. In public cloud environments, these functions are implemented by existing application load balancers, e.g. [Application Gateway](https://azure.microsoft.com/en-us/services/application-gateway/) in AKS, [Application Load Balancer](https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html) in EKS or [Google Front Ends (GFEs)](https://cloud.google.com/load-balancing/docs/https) for GKE. However, unlike a LoadBalancer controller, Kubernetes distributions do not limit the type of Ingress controller that can be deployed to perform these functions. There are over a dozen of Ingress controller implementations from the major load balancer, proxy and service mesh vendors which makes choosing the right Ingress controller a very daunting task. Several attempts have been made to compile a decision matrix to help with this choice -- [one](https://docs.google.com/spreadsheets/d/1DnsHtdHbxjvHmxvlu7VhzWcWgLAn_Mc5L1WlhLDA__k/edit#gid=0) done by Flant and [one](https://docs.google.com/spreadsheets/d/191WWNpjJ2za6-nbG4ZoUMXMpUK8KlCIosvQB0f-oq3k/edit#gid=907731238) by learnk8s.io. Multiple Ingress controllers can be deployed in a single cluster and Ingress resources are associated with a particular controller based on the `.spec.ingressClassName` field.

Ingress controller's implementation almost always includes the following two components:

* **Controller** -- a process that communicates with the API server and collects all of the information required to successfully provision its proxies.
* **Proxy** -- a data plane component, managed by the controller (via API, plugins or plain text files), can be scaled up and down by the Horizontal Pod Autoscaler.

Typically, during the installation process, an Ingress Controller creates a Service type LoadBalancer and uses the allocated IP to update the  `.status.loadBalancer` field of all managed Ingresses. 

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=tSopwAg3hkGCBVX-7IBd&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


## Lab

For this lab exercise, we'll use one of the most popular open-source Ingress controllers --  [ingress-nginx](https://kubernetes.github.io/ingress-nginx/). 


### Preparation


Assuming that the lab environment is already [set up](/lab/), `ingress-nginx` can be set up with the following commands:

```
make ingress-setup
```

Install a LoadBalancer controller to allocate external IP for the Ingress controller

```
make metallb
```

Wait for Ingress controller to fully initialise

```
make ingress-wait 
```

Set up a couple of test Deployment and associated Ingress resources to be used in the walkthrough.

```
make ingress-prep
```

The above command sets up two ingress resources -- one doing the path-based routing and one doing the host-based routing. Use the following command to confirm that both Ingresses have been set up and assigned with an external IP:

```
$ kubectl get ing
NAME     CLASS   HOSTS      ADDRESS        PORTS   AGE
tkng-1   nginx   *          198.51.100.0   80      46s
tkng-2   nginx   prod,dev   198.51.100.0   80      26s
```


Now we can verify the path-based routing functionality:

```
$ docker exec k8s-guide-control-plane curl -s http://198.51.100.0/dev
Server address: 10.244.1.14:8080
Server name: dev-694776949d-w2fw7
Date: 29/Aug/2021:16:25:41 +0000
URI: /dev
Request ID: 6ccd350709dd92b76cdfabbcbf92d5c5

$ docker exec k8s-guide-control-plane curl -s http://198.51.100.0/prod
Server address: 10.244.1.13:8080
Server name: prod-559ccb4b56-5krn6
Date: 29/Aug/2021:16:25:50 +0000
URI: /prod
Request ID: 2fed2ada42daf911057c798e74504453
```

And the host-based routing:

```
$ docker exec k8s-guide-control-plane curl -s --resolve prod:80:198.51.100.0  http://prod
Server address: 10.244.1.13:8080
Server name: prod-559ccb4b56-5krn6
Date: 29/Aug/2021:16:25:58 +0000
URI: /
Request ID: 8b28ba1ccab240700a6264024785356b

$ docker exec k8s-guide-control-plane curl -s --resolve dev:80:198.51.100.0  http://dev
Server address: 10.244.1.14:8080
Server name: dev-694776949d-w2fw7
Date: 29/Aug/2021:16:26:08 +0000
URI: /
Request ID: 5c8a8cfa037a2ece0c3cfe8fd2e1597d
```

To confirm that the HTTP routing is correct, take note of the `Server name` field of the response, which should match the name of the backend Pod:

```
$ kubectl get pod
NAME                    READY   STATUS    RESTARTS   AGE
dev-694776949d-w2fw7    1/1     Running   0          10m
prod-559ccb4b56-5krn6   1/1     Running   0          10m
```

### Walkthrough

Let's start by looking at the Ingress controller logs to see what happens when a new Ingress  resource gets added to the API server:

```
$ kubectl logs deploy/ingress-controller-ingress-nginx-controller 
I0826 16:10:40.364640       8 main.go:101] "successfully validated configuration, accepting" ingress="tkng-1/default"
I0826 16:10:40.371315       8 store.go:365] "Found valid IngressClass" ingress="default/tkng-1" ingressclass="nginx"
I0826 16:10:40.371770       8 event.go:282] Event(v1.ObjectReference{Kind:"Ingress", Namespace:"default", Name:"tkng-1", UID:"8229d775-0a73-4484-91bf-fdb9053922b5", APIVersion:"networking.k8s.io/v1", ResourceVersion:"22155", FieldPath:""}): type: 'Normal' reason: 'Sync' Scheduled for sync
I0826 16:10:40.372381       8 controller.go:150] "Configuration changes detected, backend reload required"
ingress.networking.k8s.io/tkng-1 created
I0826 16:10:40.467838       8 controller.go:167] "Backend successfully reloaded"
I0826 16:10:40.468147       8 event.go:282] Event(v1.ObjectReference{Kind:"Pod", Namespace:"kube-system", Name:"ingress-controller-ingress-nginx-controller-84d5f6c695-pd54s", UID:"b6b63172-0240-41fb-a110-e18f475caddf", APIVersion:"v1", ResourceVersion:"14712", FieldPath:""}): type: 'Normal' reason: 'RELOAD' NGINX reload triggered due to a change in configuration
I0826 16:11:29.812516       8 status.go:284] "updating Ingress status" namespace="default" ingress="tkng-1" currentValue=[] newValue=[{IP:198.51.100.0 Hostname: Ports:[]}]
I0826 16:11:29.818436       8 event.go:282] Event(v1.ObjectReference{Kind:"Ingress", Namespace:"default", Name:"tkng-1", UID:"8229d775-0a73-4484-91bf-fdb9053922b5", APIVersion:"networking.k8s.io/v1", ResourceVersion:"22343", FieldPath:""}): type: 'Normal' reason: 'Sync' Scheduled for sync
```

Most of the above log is self-explanatory -- we see that the controller performs some initial validations, updates the configuration, triggers a proxy reload and updates the status field of the managed Ingress. We can see where the allocated IP is coming from by looking at the associated LoadBalancer service:

```
$ kubectl -n kube-system get svc -l app.kubernetes.io/name=ingress-nginx
NAME                                          TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
ingress-controller-ingress-nginx-controller   LoadBalancer   10.96.193.245   198.51.100.0   80:30881/TCP,443:31634/TCP   36m
```

Now that we know what happens when a new Ingress is processed, let's take a look inside the Ingress controller pod


```
$ kubectl -n kube-system exec -it deploy/ingress-controller-ingress-nginx-controller -- pgrep -l nginx
8 /nginx-ingress-controller
31 nginx: master process /usr/local/nginx/sbin/nginx -c /etc/nginx/nginx.conf
579 nginx: worker process
580 nginx: worker process
581 nginx: worker process
582 nginx: worker process
583 nginx: worker process
584 nginx: worker process
585 nginx: worker process
586 nginx: worker process
587 nginx: cache manager process
```

Here we see to main components described above -- a controller called `nginx-ingress-controller` and a proxy process `/usr/local/nginx/sbin/nginx`. We also see that the proxy is started with the `-c` argument, pointing it at the configuration file. If we look inside this configuration file, we should see the host-based routing [`server_name`](https://nginx.org/en/docs/http/ngx_http_core_module.html#server_name) directives:
```
$ kubectl -n kube-system exec -it deploy/ingress-controller-ingress-nginx-controller -- cat /etc/nginx/nginx.conf | grep server_name
        server_names_hash_max_size      1024;
        server_names_hash_bucket_size   32;
        server_name_in_redirect off;
                server_name _ ;
                server_name dev ;
                server_name prod ;
```

Similarly, we can view the path-based routing [`location`](https://nginx.org/en/docs/http/ngx_http_core_module.html#location) directives:

```
kubectl exec -it deploy/ingress-controller-ingress-nginx-controller -- cat /etc/nginx/nginx.conf | grep "location /"
                location /prod/ {
                location /dev/ {
                location / {
                location /healthz {
                location /nginx_status {
                location / {
                location / {
                location / {
                location /healthz {
                location /is-dynamic-lb-initialized {
                location /nginx_status {
                location /configuration {
                location / {
```

Examining the plain `nginx.conf` configuration can be a bit difficult, especially for large configs. A simpler way of doing it is using an [ingress-nginx plugin](https://kubernetes.github.io/ingress-nginx/kubectl-plugin/) for kubectl which can be installed with [krew](https://krew.sigs.k8s.io/docs/user-guide/setup/install/). For example, this is how we could list all active Ingress resources managed by this controller:


```
$ kubectl ingress-nginx ingresses --all-namespaces
NAMESPACE   INGRESS NAME   HOST+PATH   ADDRESSES      TLS   SERVICE   SERVICE PORT   ENDPOINTS
default     tkng-1         /prod       198.51.100.0   NO    prod      8080           1
default     tkng-1         /dev        198.51.100.0   NO    dev       8080           1
default     tkng-2         prod/       198.51.100.0   NO    prod      8080           1
default     tkng-2         dev/        198.51.100.0   NO    dev       8080           1
```

Backend objects are [not managed](https://kubernetes.github.io/ingress-nginx/how-it-works/#avoiding-reloads-on-endpoints-changes) via a configuration file, so you won't see them in the `nginx.conf` rendered by the controller. The only way to view them is using the `ingress-nginx` plugin, e.g.:

```
$ kubectl ingress-nginx -n kube-system backends --deployment ingress-controller-ingress-nginx-controller | jq -r '.[] | "\(.name) => \(.endpoints)"'
default-dev-8080 => [{"address":"10.244.1.16","port":"8080"}]
default-prod-8080 => [{"address":"10.244.2.14","port":"8080"}]
upstream-default-backend => [{"address":"127.0.0.1","port":"8181"}]
```


{{% notice warning %}}
The above walkthrough is only applicable to the `nginx-ingress` controller. Other controllers may implement the same functionality differently, even if the data plane proxy is the same (e.g. nginx-ingress vs F5 nginx Ingress controller). Ingress API changes do not necessarily result in a complete proxy reload, assuming the underlying proxy supports hot restarts, e.g. [Envoy](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/hot_restart).
{{% /notice %}}