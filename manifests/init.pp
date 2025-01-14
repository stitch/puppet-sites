# setup generic config for nginx/php/mysql sites
class sites (
  ## default vhost
  $realm=$::fqdn,
  $default_vhost_content='',

  ## db related
  $manage_mysql=true,
  $mysql_backuprotate=2,
  $pma=false,
  $pma_allow=[],

  ## global vhost settings
  # enable ssl
  $ssl=true,
  # use more secure/less backward compatible ssl settings
  $ssl_secure=true,
  $root='/var/www',
  $dh_keysize=2048,

  # optional DNS resolver(s) to be used for proxy lookups
  $resolver=undef,

  ## resource hashes for hiera
  $apps_static_php={},
  $apps_wordpress={},

  $vhost_webroot={},
  $vhost_proxy={},

  # whether to respond to any other requests other then for explicitly declared vhosts
  $default_host=false,
){
  # TODO include php module in every php subresource

  create_resources(sites::apps::static_php, $apps_static_php, {})
  create_resources(sites::apps::wordpress, $apps_wordpress, {})

  create_resources(sites::vhosts::webroot, $vhost_webroot, {})
  create_resources(sites::vhosts::proxy, $vhost_proxy, {})

  # configure global letsencrypt if SSL is enabled
  if $ssl {
    class { 'letsencrypt': }

    if $::letsencrypt::email {
      File['/etc/letsencrypt.sh/config']
      ~> exec {'register letsencrypt':
        command => '/etc/letsencrypt.sh/letsencrypt.sh --register --accept-terms',
        refreshonly => true
      }
    }
  }

  # only offer secure ssl ciphers:
  # https://blog.qualys.com/ssllabs/2013/08/05/configuring-apache-nginx-and-openssl-for-forward-secrecy
  if $ssl_secure {
    $ssl_protocols = 'TLSv1.3 TLSv1.2'

      $ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384'

      $ssl_dhparam = '/etc/nginx/ffdhe2048.pem'

      # improve DH key for Forward secrecy
      file {$ssl_dhparam:
        source => 'puppet:///modules/sites/ffdhe2048.pem'
      }
  } else {
    # offer default configuration of compatible ciphers
    $ssl_ciphers = undef
    $ssl_dhparam = undef
  }

  # nginx
  class {'nginx':
    package_ensure          => latest,
    # global caching settings
    fastcgi_cache_path      => '/var/cache/nginx/',
    fastcgi_cache_key       => '"$scheme$request_method$host$request_uri"',
    fastcgi_cache_keys_zone => 'default:250m',
    fastcgi_cache_max_size  => '500m',
    fastcgi_cache_inactive  => '30m',
    fastcgi_cache_use_stale => 'updating timeout error',
    names_hash_bucket_size  => 80,
    http_cfg_append         => {
      fastcgi_cache_lock => on,
    },
    log_format              => {
      cache => '$remote_addr - $upstream_cache_status [$time_local] $request $status $body_bytes_sent $http_referer $http_user_agent',
    },
    # enable compression on all responses
    gzip_proxied            => any,
    gzip_types              => '*',
    gzip_vary               => on,
    # enable http/2 support
    http2                   => on,
    # remove unmanaged resources
    server_purge            => true,
    confd_purge             => true,
    server_tokens           => off,
  }

  file {
    $root:
      ensure => directory;
    '/var/cache/nginx':
      ensure => directory;
  }

  # dbs
  if $manage_mysql {
    class { '::mysql::server':
      # a random password is generated for mysql root (and backup)
      # to login as mysql root use `mysql` as root user or sudo `sudo -i mysql`
      root_password           => simplib::passgen('mysql_root', {'length' => 32}),
      remove_default_accounts => true,
    }
    class { '::mysql::server::backup':
      backupuser        => backup,
      backuppassword    => simplib::passgen('mysql_backup', {'length' => 32}),
      backupdir         => '/var/backups/mysql/',
      file_per_database => true,
      backuprotate      => $mysql_backuprotate,
    }

    # generate timezone information and load into mysql
    package {'tzdata': }
    -> Class['mysql::server']
    -> exec { 'generate mysql timezone info sql':
      command => '/usr/bin/mysql_tzinfo_to_sql /usr/share/zoneinfo > /var/lib/mysql/tzinfo.sql',
      creates => '/var/lib/mysql/tzinfo.sql',
    }
    ~> exec { 'import mysql timezone info sql':
      command     => '/usr/bin/mysql  --defaults-file=/root/.my.cnf mysql < /var/lib/mysql/tzinfo.sql',
      refreshonly => true,
    }
  }

  if $default_host {
    if $default_vhost_content {
      # default realm vhost
      sites::vhosts::vhost {$realm:
          default_vhost    => true,
          nowww_compliance => 'class_c',
          rewrite_to_https => false,
      }
      file { "/var/www/${realm}/html/index.html":
        content => $default_vhost_content,
      }
    } else {
      # deny requests on default vhost with an empty response
      sites::vhosts::disabled {$realm:
        default_vhost    => true,
        nowww_compliance => 'class_c',
      }
    }
  }

  if $pma {
    # phpmyadmin
    File['/var/www/phpmyadmin/html/']
    -> class { 'phpmyadmin':
        path    => '/var/www/phpmyadmin/html/pma',
        user    => 'www-data',
        servers => [
            {
                desc => 'local',
                host => '127.0.0.1',
            },
        ],
    }
    sites::vhosts::php{ 'phpmyadmin':
        server_name    => "phpmyadmin.${realm}",
        location_allow => $pma_allow,
        location_deny  => ['all'],
    }
  }
}
