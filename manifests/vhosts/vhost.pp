# generic vhost
# supports subdomains, ssl, ipv6, caching and no-www
define sites::vhosts::vhost (
  # domain name settings
  $domain=$name,
  $realm=$sites::realm,
  $default_vhost=false,
  # additional subdomains (no www.)
  $subdomains=[],
  # http://web.archive.org/web/20101230024259/http://no-www.org:80/index.php
  Pattern[/^class_[abc]$/]
    $nowww_compliance='class_b',
  # connection settings
  $ipv6=true,
  # SSL settings
  $ssl=$::sites::ssl,
  $rewrite_to_https=$::sites::ssl,
  $ssl_ciphers=$::sites::ssl_ciphers,
  $ssl_protocols=$::sites::ssl_protocols,
  $ssl_dhparam=$::sites::ssl_dhparam,
  # cache settings
  $expires='10m',
  $static_expires='30d',
  # access settings
  $location_allow=undef,
  $location_deny=undef,
  # paths
  $root="${::sites::root}/${name}/",
  $vhost_cfg_append={},
  $clacks_overhead=true,
  $proxy=undef,
  $resolver=undef,
  $location_cfg_append=undef,
  # configure client certificate authentication using this CA
  $client_ca=undef,
  Optional[String] $auth_basic=undef,
  Optional[String] $auth_basic_user_file=undef,
  # abstract cache configurations
  $caching=undef,
  $proxy_timeout='10s',
){
  if $default_vhost {
    $server_name = '_'
    $letsencrypt_name = $realm

    # only include a realm domain for this vhost if responing on defaulthost
    if $default_vhost {
      $realm_name = $realm
    }

    $listen_options = 'default_server'
    $ipv6_listen_options = 'default_server'

    if $nowww_compliance != 'class_c' {
      fail('realm must have Class C nowww compliance')
    }
  } else {
    $server_name = $name
    $letsencrypt_name = $server_name

    # only include a realm domain for this vhost if responing on defaulthost
    if $default_vhost {
      $realm_host = regsubst($server_name, '\.', '-')
      $realm_name = "${realm_host}.${realm}"
    } else {
      $realm_name = undef
    }

    $listen_options = ''
    $ipv6_listen_options = ''
  }

  if $ssl {
    $certfile = "${::letsencrypt::cert_root}/${letsencrypt_name}/fullchain.pem"
    $keyfile = "${::letsencrypt::cert_root}/${letsencrypt_name}/privkey.pem"
    $ssl_headers = {
      'Strict-Transport-Security' => 'max-age=31536000; includeSubdomains',
    }
  } else {
    $certfile = undef
    $keyfile = undef
    $ssl_headers = {}
  }

  # array of all provided hostnames
  $server_names = concat([], $server_name, $subdomains, $realm_name)

  # configure non-www compliancy
  # http://web.archive.org/web/20101230024259/http://no-www.org:80/faq.php
  # www point to the same content as non-www domains
  if $nowww_compliance == 'class_a' {
    $rewrite_www_to_non_www = false
    # add letsencrypt hostnames with www for every hostname
    $le_subdomains = unique(concat($subdomains, prefix(concat([], $letsencrypt_name, $subdomains), 'www.'), $realm_name))
    # listen to name, subdomains and all www. version of them
    $listen_domains = concat([], $server_name, $subdomains, $realm_name).filter |$x| {!empty($x)}
    $validate_domains = join($server_names, ' ')
    if $validate_domains !~ /^(?!.*www\.).*$/ {
      fail("Class A no-www compliance specified, but www. domain specified in title or subdomains : ${validate_domains}.")
    }
  }
  # www domains redirect to non-www domains
  if $nowww_compliance == 'class_b' {
    $rewrite_www_to_non_www = true
    # add letsencrypt hostnames with www for every hostname
    $le_subdomains = unique(concat($subdomains, prefix(concat([], $letsencrypt_name, $subdomains), 'www.'), $realm_name))
    # www-redirect manages www names, only listen to name and subdomains
    $listen_domains = concat([], $server_name, $subdomains, $realm_name)
    $validate_domains = join($server_names, ' ')
    if $validate_domains !~ /^(?!.*www\.).*$/ {
      fail("Class B no-www compliance specified, but www. domain specified in title or subdomains : ${validate_domains}.")
    }
  }
  # www domains do not exist
  if $nowww_compliance == 'class_c' {
    $rewrite_www_to_non_www = false
    $le_subdomains = unique(concat($subdomains, $realm_name))
    # only listen to name and subdomains
    $listen_domains = concat([], $server_name, $subdomains, $realm_name)
    $validate_domains = join($server_names, ' ')
    if $validate_domains !~ /^(?!.*www\.).*$/ {
      fail("Class C no-www compliance specified, but a wwww. domain in subdomains: ${validate_domains}.")
    }
  }

  if $clacks_overhead {
    $clacks_headers = {
      'X-Clacks-Overhead' => 'GNU Terry Pratchett',
    }
  } else {
    $clacks_headers = {}
  }

  if $client_ca {
    file { "/etc/ssl/certs/nginx-client-ca-${name}.pem":
      content => $client_ca,
    }
    $ssl_client_cert = "/etc/ssl/certs/nginx-client-ca-${name}.pem"
    $ssl_verify_client = on
  } else {
    $ssl_client_cert = undef
    $ssl_verify_client = undef
  }

  case $caching {
    # expect upstream (php, uwsgi, proxy) to provide caching headers
    # provide default caching if upstream does not provide one
    # cache upstream responses in webserver
    # server stale content from cache if upstream is unavailable
    upstream: {
      $vhost_cfg_cache = {
        # return stale content for all problems with backend
        proxy_cache_use_stale         => 'error timeout invalid_header updating http_404 http_500 http_502 http_503 http_504 http_429',
        proxy_cache_background_update => on,
        # log cache performance to separate log (hit, miss, expired, stale, etc)
        access_log                    => "/var/log/nginx/${server_name}.cache.log cache",
        # set upstream or fallback on default expiry header
        expires                       => "\$default_expires",
        # enable caching
        proxy_cache                   => $server_name,
        # caching doesn't pick up on the map hack to set default cache headers if none are provided upstream
        # use this setting to fallback on the configured default cache time
        proxy_cache_valid             => "200 302 ${expires}",

      }
      # https://stackoverflow.com/a/41362362
      nginx::resource::map { 'default_expires':
        string   => "\$upstream_http_expires",
        mappings => {
          "''" => $expires,
        }
      }
      # setup a cache configuration with 10MB memory store, 1GB disk cache
      file { "/etc/nginx/conf.d/${server_name}.cache.conf":
        ensure  => present,
        content => "proxy_cache_path /var/cache/nginx/${server_name}/ inactive=14d \
                    levels=1:2 keys_zone=${server_name}:10m max_size=1g use_temp_path=off;"
      } -> Nginx::Resource::Server[$name]
    }
    # disable all caching except static files, also prevent upstream cache headers from propagating
    disabled: {
      $vhost_cfg_cache = {
        proxy_ignore_headers => 'Expires Cache-Control',
        expires              => -1,
      }
    }
    # use old cache configuration if caching method is not defined
    default: {
      $vhost_cfg_cache = {
        expires    => $expires,
        access_log => "/var/log/nginx/${server_name}.cache.log cache",
      }
    }
  }

  $listen_domains_for_csp_header = join(prefix(suffix($listen_domains, "'"), "'"), " ")
  $security_headers = {
    # prevent browser from rendering page if it detects XSS attack
    'X-XSS-Protection' => '1; mode=block',
    # tell browser to deny any form of framing
    'X-Frame-Options'           => 'SAMEORIGIN',
    # do not execute css/js if content-type is not valid
    'X-Content-Type-Options'    => nosniff,
    # strict script-src and style-src CSP is currently blocked by VUE.js components (lmap.js) which inlines script into the DOM.
    'Content-Security-Policy' => regsubst("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' https://*.tile.osm.org; frame-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'; object-src 'none';", "'", "\\\\\'", 'G'),
    'Referrer-Policy' => 'same-origin',
  }

  # convert headers into list of add_header statements as puppet-nginx==6 doesn't support
  # adding the 'always' argument
  $headers_cfg_append = suffix(prefix(
    join_keys_to_values(
      merge($ssl_headers, $security_headers, $clacks_headers), "' '"),
        "add_header '"),
          "' always;")

  file {
    $root:
      ensure => directory,
      owner  => www-data,
      group  => www-data;
  }
  -> nginx::resource::server { $name:
    server_name           => $listen_domains,
    listen_options        => $listen_options,
    ipv6_listen_options   => $ipv6_listen_options,
    ipv6_enable           => true,
    ssl                   => $ssl,
    ssl_key               => $keyfile,
    ssl_cert              => $certfile,
    ssl_ciphers           => $ssl_ciphers,
    ssl_protocols    => $ssl_protocols,
    ssl_dhparam           => $ssl_dhparam,
    location_allow        => $location_allow,
    location_deny         => $location_deny,
    server_cfg_append     => merge(
      $vhost_cfg_cache,
      $vhost_cfg_append
    ),
    raw_append            => $headers_cfg_append,
    proxy                 => $proxy,
    resolver              => $resolver,
    location_cfg_append   => $location_cfg_append,
    # ssl client certificate verification
    ssl_client_cert       => $ssl_client_cert,
    ssl_verify_client     => $ssl_verify_client,
    # basic auth
    auth_basic            => $auth_basic,
    auth_basic_user_file  => $auth_basic_user_file,
    # ignore security headers from upstream and enforce on webserver level
    proxy_hide_header     => [
      'X-Frame-Options',
      'X-Content-Type-Options',
      'X-XSS-Protection'
    ],
    proxy_read_timeout    => $proxy_timeout,
    proxy_connect_timeout => $proxy_timeout,
    proxy_send_timeout    => $proxy_timeout,
  }

  # redirect to https but allow .well-known undirected to not break LE.
  # overrides default location to redirect to https
  if $rewrite_to_https {
    nginx::resource::location { "${name}-ssl-redirect":
      ensure              => present,
      server              => $name,
      location            => '~* /.*',
      ssl                 => false,
      location_custom_cfg => {
        return => '301 https://$host$request_uri',
      }
    }
  }

  # redirect to non-www but allow .well-known undirected to not break LE.
  if $rewrite_www_to_non_www {
    nginx::resource::server { "www-${name}":
      server_name         => prefix($listen_domains, 'www.'),
      listen_options      => $listen_options,
      ipv6_listen_options => $ipv6_listen_options,
      ipv6_enable         => true,
      ssl                 => $ssl,
      ssl_key             => $keyfile,
      ssl_cert            => $certfile,
      ssl_ciphers         => $ssl_ciphers,
      ssl_dhparam         => $ssl_dhparam,
      location_allow      => $location_allow,
      location_deny       => $location_deny,
      server_cfg_append   => merge(
        $vhost_cfg_cache,
        $vhost_cfg_append
      ),
      raw_append          => $headers_cfg_append,
      location_custom_cfg => {
        return => "301 \$scheme://${name}\$request_uri",
      },
      proxy               => $proxy,
      resolver            => $resolver,
      location_cfg_append => $location_cfg_append,
      # ssl client certificate verification
      ssl_client_cert     => $ssl_client_cert,
      ssl_verify_client   => $ssl_verify_client,
    }
  }

  # configure letsencrypt
  if $ssl {
    letsencrypt::domain{ $letsencrypt_name:
      subdomains => $le_subdomains,
    }
    nginx::resource::location { "letsencrypt_${name}":
      location       => '^~ /.well-known/acme-challenge',
      server         => $name,
      location_alias => $::letsencrypt::www_root,
      priority       => 401,
      auth_basic     => off,
    }
    if $rewrite_www_to_non_www {
      nginx::resource::location { "letsencrypt_www-${name}":
        location       => '^~ /.well-known/acme-challenge',
        server         => "www-${name}",
        location_alias => $::letsencrypt::www_root,
        priority       => 401,
        auth_basic     => off,
      }
    }
  }

  sites::vhosts::monitoring {$name:
    server_name => $server_name,
  }
}
