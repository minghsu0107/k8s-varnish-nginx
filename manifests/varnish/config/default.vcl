# reference: https://www.varnish-software.com/developers/tutorials/varnish-builtin-vcl/
vcl 4.1;

import dynamic;
import std;

# backend will be resolved dynamically
backend default none;

acl purge {
	"localhost";
	"127.0.0.1";
	"::1";

	# pod ip range for k3s cluster
	"10.42.0.0/16";
}

sub vcl_init {
	new d = dynamic.director(port = "80");
}

sub vcl_recv {
	if (req.method == "PRI") {
		# HTTP/2 request
		# This will never happen in properly formed traffic (see: RFC7540)
		return (synth(405));
	}
	if(req.url == "/healthcheck") {
		return(synth(200,"OK"));
	}
	# backend hint for vmod dynamic
	set req.backend_hint = d.backend("nginx");

	# Serve objects up to 2 minutes past their expiry if the backend is slow to respond.
    set req.grace = 120s;

	if (req.restarts == 0) {
        if (req.http.X-Forwarded-For) {
            set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }

    # Normalize the header, remove the port (in case you're testing this on various TCP ports)
    set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

	# Remove empty query string parameters
	# e.g.: www.example.com/index.html?
	if (req.url ~ "\?$") {
		set req.url = regsub(req.url, "\?$", "");
	}

	# Strip hash, server doesn't need it.
    if (req.url ~ "\#") {
        set req.url = regsub(req.url, "\#.*$", "");
    }

	# Sorts query string parameters alphabetically for cache normalization purposes
	set req.url = std.querysort(req.url);

	# Remove the proxy header to mitigate the httpoxy vulnerability
	# See https://httpoxy.org/
	unset req.http.proxy;

	# Purge logic to remove objects from the cache.
	# See https://wordpress.org/plugins/varnish-http-purge/
	if(req.method == "PURGE") {
		if(!client.ip ~ purge) {
			return(synth(405,"PURGE not allowed for this IP address"));
		}
		# A purge is what happens when you pick out an object from the cache and discard it along with its variants
        return (purge);
	}

	# Only handle relevant HTTP request methods
	if (
		req.method != "GET" &&
		req.method != "HEAD" &&
		req.method != "PUT" &&
		req.method != "POST" &&
		req.method != "PATCH" &&
		req.method != "TRACE" &&
		req.method != "OPTIONS" &&
		req.method != "DELETE"
	) {
		# Using pipe means Varnish stops inspecting each request
		# and just sends bytes straight to the backend
		return (pipe);
	}

	# Remove tracking query string parameters used by analytics tools
	if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
		set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
		set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
		set req.url = regsub(req.url, "\?&", "?");
		set req.url = regsub(req.url, "\?$", "");
	}

	# Only cache GET and HEAD requests
	if (req.method != "GET" && req.method != "HEAD") {
		set req.http.X-Cacheable = "NO:REQUEST-METHOD";
		return(pass);
	}

	# sitemap.xml is dynamically generated
	if (req.url ~ "^/sitemap(-.*)?\.xml") {
		set req.http.X-Cacheable = "NO:Sitemap";
		return(pass);
	}

	# robots.txt is dynamically generated
	if (req.url ~ "^/robots\.txt") {
		set req.http.X-Cacheable = "NO:robots.txt";
		return(pass);
	}

	# Some generic cookie manipulation, useful for all templates that follow
    # Remove the "has_js" cookie
    set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");
    # Remove any Google Analytics based cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");
    # Remove the Quant Capital cookies (added by some plugin, all __qca)
    set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");
    # Remove a ";" prefix, if present.
    set req.http.Cookie = regsub(req.http.Cookie, "^;\s*", "");
    # remove newrelic
    set req.http.Cookie = regsuball(req.http.Cookie, "NREUM=[^;]*", "");
    # remove ASP
    set req.http.Cookie = regsuball(req.http.Cookie, "ASP.NET_SessionId=[^;]*", "");

    # Are there cookies left with only spaces or that are empty?
    if (req.http.cookie ~ "^ *$") {
        unset req.http.cookie;
    }

	# Normalize Accept-Encoding header
    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
            # No point in compressing these
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            # unkown algorithm
            unset req.http.Accept-Encoding;
        }
    }

	# Remove all cookies for static files
    if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|mp[34]|pdf|png|rar|rtf|swf|tar|tgz|txt|wav|woff|xml|zip)(\?.*)?$") {
        unset req.http.Cookie;
    }

	# Example of no caching of special URLs
	# ^/admin($|/.*) means /admin or /admin/*
	if (
		req.url ~ "^/admin($|/.*)" ||
		req.url ~ "/(login|monitor)" ||
		req.url ~ "/wp-(login|admin)"
	) {
		return(pass);
	}

	if (req.http.Authorization) {
        # Not cacheable by default
        return (pass);
    }
	return (hash);
}

sub vcl_pipe {
    # By default Connection: close is set on all piped requests, to stop
    # connection reuse from sending future requests directly to the
    # (potentially) wrong backend. If you do want this to happen, you can undo
    # it here.
    # unset bereq.http.connection;
    return (pipe);
}

sub vcl_pass {
    return (fetch);
}

# The data on which the hashing will take place
sub vcl_hash {
    hash_data(req.url);

    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }

	if(req.http.X-Forwarded-Proto) {
		# Create cache variations depending on the request protocol
		hash_data(req.http.X-Forwarded-Proto);
	}

    # hash cookies for object with auth
    if (req.http.Cookie) {
        hash_data(req.http.Cookie);
    }

    if (req.http.Authorization) {
        hash_data(req.http.Authorization);
    }

    # If the client supports compression, keep that in a different cache
    if (req.http.Accept-Encoding) {
        hash_data(req.http.Accept-Encoding);
    }

    # Do a cache-lookup
    # That will force entry into vcl_hit() or vcl_miss()
    return (lookup);
}

# https://varnish-cache.org/docs/4.0/users-guide/purging.html
sub vcl_purge {
    return (synth(200, "Purged"));
}

sub vcl_hit {
    /*
    if (obj.ttl >= 0s) {
        // A pure unadulterated hit, deliver it
        return (deliver);
    }
    if (obj.ttl + obj.grace > 0s) {
        // Object is in grace, deliver it
        // Automatically triggers a background fetch
        return (deliver);
    }
    */
    return (deliver);
}

sub vcl_miss {
    return (fetch);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache-Hits = obj.hits;
        set resp.http.X-Cache = "cached";
    } else {
        set resp.http.X-Cache = "uncached";
    }

    # Remove some headers: PHP version
    unset resp.http.X-Powered-By;
    # Remove some headers: Apache version & OS
    unset resp.http.Server;
    unset resp.http.X-Drupal-Cache;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;

    return (deliver);
}

sub vcl_synth {
    set resp.http.Content-Type = "text/html; charset=utf-8";
    set resp.http.Retry-After = "5";
    set resp.body = {"<!DOCTYPE html>
<html>
  <head>
    <title>"} + resp.status + " " + resp.reason + {"</title>
  </head>
  <body>
    <h1>Error "} + resp.status + " " + resp.reason + {"</h1>
    <p>"} + resp.reason + {"</p>
    <h3>Guru Meditation:</h3>
    <p>XID: "} + req.xid + {"</p>
    <hr>
    <p>Varnish cache server</p>
  </body>
</html>
"};
    return (deliver);
}

# Only called when the object cannot be served from the cache. 
# This happens when a cache miss occurs or when requests bypasses the cache.
sub vcl_backend_fetch {
	# the request body is removed for GET requests
    if (bereq.method == "GET") {
        unset bereq.body;
    }
    return (fetch);
}

sub vcl_backend_response {
    # Serve objects up to 2 minutes past their expiry if the backend is slow to respond.
    set beresp.grace = 2m;

    # Default cache time, 2 minutes
    set beresp.ttl = 5m;

    if (bereq.uncacheable) {
        return (deliver);
    } else if (beresp.ttl <= 0s ||
      beresp.http.Set-Cookie ||
      beresp.http.Surrogate-control ~ "(?i)no-store" ||
      (!beresp.http.Surrogate-Control &&
        beresp.http.Cache-Control ~ "(?i:no-cache|no-store|private)") ||
      beresp.http.Vary == "*") {
        # Mark as "Hit-For-Miss" for the next 2 minutes
        set beresp.ttl = 120s;
        set beresp.uncacheable = true;
    }
    return (deliver);
}

sub vcl_backend_error {
    set beresp.http.Content-Type = "text/html; charset=utf-8";
    set beresp.http.Retry-After = "5";
    set beresp.body = {"<!DOCTYPE html>
<html>
  <head>
    <title>"} + beresp.status + " " + beresp.reason + {"</title>
  </head>
  <body>
    <h1>Error "} + beresp.status + " " + beresp.reason + {"</h1>
    <p>"} + beresp.reason + {"</p>
    <h3>Guru Meditation:</h3>
    <p>XID: "} + bereq.xid + {"</p>
    <hr>
    <p>Varnish cache server</p>
  </body>
</html>
"};
    return (deliver);
}

sub vcl_fini {
    return (ok);
}