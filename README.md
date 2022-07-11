# k8s-varnish-nginx
This repository domonstrates how to deploy Varnish, a high-performance caching HTTP reverse proxy, on Kubernetes.
## Deployment
Apply manifests:
```bash
kustomize build manifests | kubectl apply -f -
```
## Testing
Open port-forward to varnish service:
```bash
kubectl -n demo port-forward svc/varnish 8008:80
```
Test whether caching works:
```bash
curl -v http://localhost:8008
```
Example of a successful response:
```
*   Trying 127.0.0.1:8008...
* Connected to localhost (127.0.0.1) port 8008 (#0)
> GET / HTTP/1.1
> Host: localhost:8008
> User-Agent: curl/7.79.1
> Accept: */*
> 
* Mark bundle as not supporting multiuse
< HTTP/1.1 200 OK
< Date: Mon, 11 Jul 2022 09:03:33 GMT
< Content-Type: text/html
< Content-Length: 615
< Last-Modified: Mon, 23 May 2022 23:59:19 GMT
< ETag: "628c1fd7-267"
< Age: 21
< Accept-Ranges: bytes
< X-Cache-Hits: 3
< X-Cache: cached
< Connection: keep-alive
< 
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
* Connection #0 to host localhost left intact
```
We can see that Varnish has cached the Nginx welcome page for us, resulting in `X-Cache: cached` and `X-Cache-Hits: 3`.
