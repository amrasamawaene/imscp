=head1 NAME

 Servers::httpd::apache_php_fpm::installer - i-MSCP Apache2/PHP-FPM Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2017 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package Servers::httpd::apache_php_fpm::installer;

use strict;
use warnings;
use Cwd;
use File::Basename;
use iMSCP::Crypt qw/ randomStr /;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::File;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::Getopt;
use iMSCP::ProgramFinder;
use iMSCP::SystemGroup;
use iMSCP::SystemUser;
use iMSCP::TemplateParser;
use Servers::httpd::apache_php_fpm;
use Servers::sqld;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Installer for the i-MSCP Apache2/PHP-FPM Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners( \%eventManager )

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ($self, $eventManager) = @_;

    $eventManager->register(
        'beforeSetupDialog',
        sub {
            push @{$_[0]}, sub { $self->showPhpConfigLevelDialog( @_ ) }, sub { $self->showListenModeDialog( @_ ) };
            0;
        }
    );
}

=item showPhpConfigLevelDialog( \%dialog )

 Ask for PHP configuration level to use

 Param iMSCP::Dialog \%dialog
 Return int 0 to go on next question, 30 to go back to the previous question

=cut

sub showPhpConfigLevelDialog
{
    my ($self, $dialog) = @_;

    my $confLevel = main::setupGetQuestion( 'PHP_CONFIG_LEVEL', $self->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} );

    if ( $main::reconfigure =~ /^(?:httpd|php|servers|all|forced)$/ || $confLevel !~ /^per_(?:site|domain|user)$/ ) {
        $confLevel =~ s/_/ /;
        ( my $rs, $confLevel ) = $dialog->radiolist(
            <<"EOF", [ 'per_site', 'per_domain', 'per_user' ], $confLevel =~ /^per (?:user|domain)$/ ? $confLevel : 'per site' );

\\Z4\\Zb\\ZuPHP configuration level\\Zn

Please choose the PHP configuration level you want use. Available levels are:

\\Z4Per domain:\\Zn One pool configuration file per domain (including subdomains)
\\Z4Per user:\\Zn One pool configuration file per user
\\Z4Per site:\\Zn One pool configuration per domain
EOF
        return $rs if $rs >= 30;
    }

    ( $self->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} = $confLevel ) =~ s/ /_/;
    0;
}

=item showListenModeDialog( )

 Ask for FPM listen mode

 Param iMSCP::Dialog \%dialog
 Return int 0 to go on next question, 30 to go back to the previous question

=cut

sub showListenModeDialog
{
    my ($self, $dialog) = @_;

    my $rs = 0;
    my $listenMode = main::setupGetQuestion( 'PHP_FPM_LISTEN_MODE', $self->{'phpConfig'}->{'PHP_FPM_LISTEN_MODE'} );

    if ( $main::reconfigure =~ /^(?:httpd|php|servers|all|forced)$/ || $listenMode !~ /^(?:uds|tcp)$/ ) {
        ( $rs, $listenMode ) = $dialog->radiolist(
            <<"EOF", [ 'uds', 'tcp' ], $listenMode =~ /^(?:tcp|uds)$/ ? $listenMode : 'uds' );

\\Z4\\Zb\\ZuPHP-FPM - FastCGI address type\\Zn

Please, choose the FastCGI address type that you want use. Available types are:

\\Z4tcp:\\Zn TCP/IP (e.g. 127.0.0.1:9000)
\\Z4uds:\\Zn Unix domain socket (e.g. /run/php/php<version>-fpm-domain.tld.sock)

Be aware that for high traffic sites, TCP/IP can require a tweaking of your kernel parameters (sysctl).
EOF
    }

    $self->{'phpConfig'}->{'PHP_FPM_LISTEN_MODE'} = $listenMode if $rs < 30;
    $rs;
}

=item install( )

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ($self) = @_;

    my $rs = $self->_setApacheVersion();
    $rs ||= $self->_makeDirs();
    $rs ||= $self->_copyDomainDisablePages;
    $rs ||= $self->_buildFastCgiConfFiles();
    $rs ||= $self->_buildPhpConfFiles();
    $rs ||= $self->_buildApacheConfFiles();
    $rs ||= $self->_installLogrotate();
    $rs ||= $self->_setupVlogger();
    $rs ||= $self->_cleanup();
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Servers::httpd::apache_php_fpm::installer

=cut

sub _init
{
    my ($self) = @_;

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'httpd'} = Servers::httpd::apache_php_fpm->getInstance();
    $self->{'apacheCfgDir'} = $self->{'httpd'}->{'apacheCfgDir'};
    $self->{'config'} = $self->{'httpd'}->{'config'};
    $self->{'phpCfgDir'} = $self->{'httpd'}->{'phpCfgDir'};
    $self->{'phpConfig'} = $self->{'httpd'}->{'phpConfig'};
    $self->_guessSystemPhpVariables();
    $self;
}

=item _guessSystemPhpVariables

 Guess system PHP Variables

 Return int 0 on success, die on failure

=cut

sub _guessSystemPhpVariables
{
    my ($self) = @_;

    my ($phpVersion) = `php -nv 2> /dev/null` =~ /^PHP\s+(\d+.\d+)/ or die( "Couldn't guess system PHP version" );

    $self->{'phpConfig'}->{'PHP_VERSION'} = $phpVersion;

    my ($phpConfDir) = `php -ni 2> /dev/null | grep '(php.ini) Path'` =~ /([^\s]+)$/ or die(
        "Couldn't guess system PHP configuration directory path"
    );

    my $phpConfBaseDir = dirname( $phpConfDir );
    $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = $phpConfBaseDir;
    $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = "$phpConfBaseDir/fpm/pool.d";

    unless ( -d $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} ) {
        $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = '';
        die( sprintf( "Couldn't guess `%s' PHP configuration parameter value: directory doesn't exists.", $_ ));
    }

    $self->{'phpConfig'}->{'PHP_CLI_BIN_PATH'} = iMSCP::ProgramFinder::find( "php$phpVersion" );
    $self->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'} = iMSCP::ProgramFinder::find( "php-cgi$phpVersion" );
    $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} = iMSCP::ProgramFinder::find( "php-fpm$phpVersion" );

    for( qw/ PHP_CLI_BIN_PATH PHP_FCGI_BIN_PATH PHP_FPM_BIN_PATH / ) {
        next if $self->{'phpConfig'}->{$_};
        die( sprintf( "Couldn't guess `%s' PHP configuration parameter value.", $_ ));
    }

    0;
}

=item _setApacheVersion

 Set Apache version

 Return int 0 on success, other on failure

=cut

sub _setApacheVersion
{
    my ($self) = @_;

    my $rs = execute( 'apache2ctl -v', \ my $stdout, \ my $stderr );
    error( $stderr || 'Unknown error' ) if $rs;
    return $rs if $rs;

    if ( $stdout !~ m%Apache/([\d.]+)% ) {
        error( "Couldn't guess Apache version" );
        return 1;
    }

    $self->{'config'}->{'HTTPD_VERSION'} = $1;
    debug( sprintf( 'Apache version set to: %s', $1 ));
    0;
}

=item _makeDirs( )

 Create directories

 Return int 0 on success, other on failure

=cut

sub _makeDirs
{
    my ($self) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdMakeDirs' );
    return $rs if $rs;

    iMSCP::Dir->new( dirname => $self->{'config'}->{'HTTPD_LOG_DIR'} )->make(
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ADM_GROUP'},
            mode  => 0750
        }
    );

    # Cleanup pools directory (prevent possible orphaned pool file when changing PHP configuration level)
    unlink grep !/www\.conf$/, glob "$self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'}/*.conf";
    $self->{'eventManager'}->trigger( 'afterHttpdMakeDirs' );
}

=item _copyDomainDisablePages( )

 Copy pages for disabled domains

 Return int 0 on success, other on failure

=cut

sub _copyDomainDisablePages
{
    iMSCP::Dir->new( dirname => "$main::imscpConfig{'CONF_DIR'}/skel/domain_disabled_pages" )->rcopy(
        "$main::imscpConfig{'USER_WEB_DIR'}/domain_disabled_pages", { preserve => 'no' }
    );
    0;
}

=item _buildFastCgiConfFiles( )

 Build FastCGI configuration files

 Return int 0 on success, other on failure

=cut

sub _buildFastCgiConfFiles
{
    my ($self) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildFastCgiConfFiles' );
    return $rs if $rs;

    $self->{'httpd'}->setData(
        {
            PHP_VERSION => $self->{'phpConfig'}->{'PHP_VERSION'}
        }
    );

    $rs = $self->{'httpd'}->disableModules(
        'actions', 'fastcgi', 'fcgid', 'fcgid_imscp', 'suexec', 'php5', 'php5_cgi', 'php5filter', 'php5.6', 'php7.0',
        'php7.1', 'proxy_fcgi', 'proxy_handler', 'mpm_itk', 'mpm_event', 'mpm_prefork', 'mpm_worker'
    );
    $rs ||= $self->{'httpd'}->enableModules( 'authz_groupfile', 'mpm_event', 'proxy_fcgi', 'suexec', 'version' );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdBuildFastCgiConfFiles' );
}

=item _buildPhpConfFiles( )

 Build PHP configuration files

 Return int 0 on success, other on failure

=cut

sub _buildPhpConfFiles
{
    my ($self) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildPhpConfFiles' );
    return $rs if $rs;

    $self->{'httpd'}->setData(
        {
            HTTPD_USER                          => $self->{'config'}->{'HTTPD_USER'},
            HTTPD_GROUP                         => $self->{'config'}->{'HTTPD_GROUP'},
            PEAR_DIR                            => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
            PHP_CONF_DIR_PATH                   => $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'},
            PHP_FPM_POOL_DIR_PATH               => $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'},
            PHP_FPM_LOG_LEVEL                   => $self->{'phpConfig'}->{'PHP_FPM_LOG_LEVEL'} || 'error',
            PHP_FPM_EMERGENCY_RESTART_THRESHOLD => $self->{'phpConfig'}->{'PHP_FPM_EMERGENCY_RESTART_THRESHOLD'} || 10,
            PHP_FPM_EMERGENCY_RESTART_INTERVAL  => $self->{'phpConfig'}->{'PHP_FPM_EMERGENCY_RESTART_INTERVAL'} || '1m',
            PHP_FPM_PROCESS_CONTROL_TIMEOUT     => $self->{'phpConfig'}->{'PHP_FPM_PROCESS_CONTROL_TIMEOUT'} || '60s',
            PHP_FPM_PROCESS_MAX                 => $self->{'phpConfig'}->{'PHP_FPM_PROCESS_MAX'} // 0,
            PHP_FPM_RLIMIT_FILES                => $self->{'phpConfig'}->{'PHP_FPM_RLIMIT_FILES'} // 4096,
            PHP_VERSION                         => $self->{'phpConfig'}->{'PHP_VERSION'},
            TIMEZONE                            => main::setupGetQuestion( 'TIMEZONE' ),
            PHP_OPCODE_CACHE_ENABLED            => $self->{'phpConfig'}->{'PHP_OPCODE_CACHE_ENABLED'},
            PHP_OPCODE_CACHE_MAX_MEMORY         => $self->{'phpConfig'}->{'PHP_OPCODE_CACHE_MAX_MEMORY'}
        }
    );

    $rs = $self->{'httpd'}->buildConfFile(
        "$self->{'phpCfgDir'}/fpm/php.ini",
        {},
        {
            destination => "$self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}/fpm/php.ini"
        }
    );
    $rs ||= $self->{'httpd'}->buildConfFile(
        "$self->{'phpCfgDir'}/fpm/php-fpm.conf",
        {},
        {
            destination => "$self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}/fpm/php-fpm.conf"
        }
    );
    $rs ||= $self->{'httpd'}->buildConfFile(
        "$self->{'phpCfgDir'}/fpm/pool.conf.default",
        {},
        {
            destination => "$self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'}/www.conf"
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdBuildPhpConfFiles' );
}

=item _buildApacheConfFiles

 Build main Apache configuration files

 Return int 0 on success, other on failure

=cut

sub _buildApacheConfFiles
{
    my ($self) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildApacheConfFiles' );
    return $rs if $rs;

    if ( -f "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" ) {
        $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'apache_php_fpm', 'ports.conf', \ my $cfgTpl, {} );
        return $rs if $rs;

        unless ( defined $cfgTpl ) {
            $cfgTpl = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" )->get();
            unless ( defined $cfgTpl ) {
                error( sprintf( "Couldn't read %s file", "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" ));
                return 1;
            }
        }

        $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildConfFile', \$cfgTpl, 'ports.conf' );
        return $rs if $rs;

        $cfgTpl =~ s/^NameVirtualHost[^\n]+\n//gim;

        $rs = $self->{'eventManager'}->trigger( 'afterHttpdBuildConfFile', \$cfgTpl, 'ports.conf' );
        return $rs if $rs;

        my $file = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" );
        $file->set( $cfgTpl );

        $rs = $file->save();
        $rs ||= $file->mode( 0644 );
        return $rs if $rs;
    }

    # Turn off default access log provided by Debian package
    $rs = $self->{'httpd'}->disableConfs( 'other-vhosts-access-log.conf' );
    return $rs if $rs;

    # Remove default access log file provided by Debian package
    if ( -f "$self->{'config'}->{'HTTPD_LOG_DIR'}/other_vhosts_access.log" ) {
        $rs = iMSCP::File->new(
            filename => "$self->{'config'}->{'HTTPD_LOG_DIR'}/other_vhosts_access.log"
        )->delFile();
        return $rs if $rs;
    }

    $self->{'httpd'}->setData(
        {
            HTTPD_CUSTOM_SITES_DIR => $self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'},
            HTTPD_LOG_DIR          => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_ROOT_DIR         => $self->{'config'}->{'HTTPD_ROOT_DIR'},
            VLOGGER_CONF           => "$self->{'apacheCfgDir'}/vlogger.conf"
        }
    );

    $rs ||= $self->{'httpd'}->buildConfFile( '00_nameserver.conf' );
    $rs ||= $self->{'httpd'}->buildConfFile(
        '00_imscp.conf',
        {},
        {
            destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available/00_imscp.conf"
        }
    );
    $rs ||= $self->{'httpd'}->enableModules( 'cgid', 'headers', 'proxy', 'proxy_http', 'rewrite', 'setenvif', 'ssl' );
    $rs ||= $self->{'httpd'}->enableSites( '00_nameserver.conf' );
    $rs ||= $self->{'httpd'}->enableConfs( '00_imscp.conf' );
    $rs ||= $self->{'httpd'}->disableConfs(
        'php5.6-cgi.conf', 'php7.0-cgi.conf', 'php7.1-cgi.conf',
        'php5.6-fpm.conf', 'php7.0-fpm.conf', 'php7.1-fpm.conf',
        'serve-cgi-bin.conf'
    );
    $rs ||= $self->{'httpd'}->disableSites( 'default', 'default-ssl', '000-default.conf', 'default-ssl.conf' );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdBuildApacheConfFiles' );
}

=item _installLogrotate( )

 Install logrotate files

 Return int 0 on success, other on failure

=cut

sub _installLogrotate
{
    my ($self) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdInstallLogrotate', 'apache2' );

    $self->{'httpd'}->setData(
        {
            ROOT_USER     => $main::imscpConfig{'ROOT_USER'},
            ADM_GROUP     => $main::imscpConfig{'ADM_GROUP'},
            HTTPD_LOG_DIR => $self->{'config'}->{'HTTPD_LOG_DIR'},
            PHP_VERSION   => $self->{'phpConfig'}->{'PHP_VERSION'}
        }
    );

    $rs ||= $self->{'httpd'}->buildConfFile(
        'logrotate.conf',
        {},
        {
            destination => "$main::imscpConfig{'LOGROTATE_CONF_DIR'}/apache2"
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdInstallLogrotate', 'apache2' );

    if ( !$rs && version->parse( "$self->{'phpConfig'}->{'PHP_VERSION'}" ) < version->parse( '7.0' ) ) {
        $rs ||= $self->{'eventManager'}->trigger( 'beforeHttpdInstallLogrotate', 'php5-fpm' );
        $rs ||= $self->{'httpd'}->buildConfFile(
            "$self->{'phpCfgDir'}/fpm/logrotate.tpl",
            {},
            {
                destination => "$main::imscpConfig{'LOGROTATE_CONF_DIR'}/php5-fpm"
            }
        );
        $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdInstallLogrotate', 'php5-fpm' );
    }

    $rs;
}

=item _setupVlogger( )

 Setup vlogger

 Return int 0 on success, other on failure

=cut

sub _setupVlogger
{
    my ($self) = @_;

    my $host = main::setupGetQuestion( 'DATABASE_HOST' );
    $host = $host eq 'localhost' ? '127.0.0.1' : $host;
    my $port = main::setupGetQuestion( 'DATABASE_PORT' );
    my $dbName = main::setupGetQuestion( 'DATABASE_NAME' );
    my $user = 'vlogger_user';
    my $userHost = main::setupGetQuestion( 'DATABASE_USER_HOST' );
    $userHost = '127.0.0.1' if $userHost eq 'localhost';
    my $oldUserHost = $main::imscpOldConfig{'DATABASE_USER_HOST'};
    my $pass = randomStr( 16, iMSCP::Crypt::ALNUM );

    my $db = iMSCP::Database->factory();
    my $rs = main::setupImportSqlSchema( $db, "$self->{'apacheCfgDir'}/vlogger.sql" );
    return $rs if $rs;

    local $@;
    eval {
        my $sqlServer = Servers::sqld->factory();

        for ( $userHost, $oldUserHost, 'localhost' ) {
            next unless $_;
            $sqlServer->dropUser( $user, $_ );
        }

        $sqlServer->createUser( $user, $userHost, $pass );

        my $dbh = iMSCP::Database->factory()->getRawDb();
        local $dbh->{'RaiseError'} = 1;

        # No need to escape wildcard characters. See https://bugs.mysql.com/bug.php?id=18660
        my $qDbName = $dbh->quote_identifier( $dbName );
        $dbh->do( "GRANT SELECT, INSERT, UPDATE ON $qDbName.httpd_vlogger TO ?\@?", undef, $user, $userHost );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'httpd'}->setData(
        {
            DATABASE_NAME     => $dbName,
            DATABASE_HOST     => $host,
            DATABASE_PORT     => $port,
            DATABASE_USER     => $user,
            DATABASE_PASSWORD => $pass
        }
    );

    $self->{'httpd'}->buildConfFile(
        "$self->{'apacheCfgDir'}/vlogger.conf.tpl",
        {
            SKIP_TEMPLATE_CLEANER => 1
        },
        {
            destination => "$self->{'apacheCfgDir'}/vlogger.conf"
        }
    );
}

=item _cleanup( )

 Process cleanup tasks

 Return int 0 on success, other on failure

=cut

sub _cleanup
{
    my ($self) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdCleanup' );
    $rs ||= $self->{'httpd'}->disableSites( 'imscp.conf', '00_modcband.conf', '00_master.conf', '00_master_ssl.conf' );
    return $rs if $rs;

    if ( -f "$self->{'apacheCfgDir'}/apache.old.data" ) {
        $rs = iMSCP::File->new( filename => "$self->{'apacheCfgDir'}/apache.old.data" )->delFile();
        return $rs if $rs;
    }

    if ( -f "$self->{'phpCfgDir'}/php.old.data" ) {
        $rs = iMSCP::File->new( filename => "$self->{'phpCfgDir'}/php.old.data" )->delFile();
        return $rs if $rs;
    }

    for ( 'imscp.conf', '00_modcband.conf', '00_master.conf', '00_master_ssl.conf' ) {
        next unless -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_";
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_" )->delFile();
        return $rs if $rs;
    }

    $rs = $self->{'httpd'}->disableModules( 'php_fpm_imscp', 'fastcgi_imscp' );
    return $rs if $rs;

    for( 'fastcgi_imscp.conf', 'fastcgi_imscp.load', 'php_fpm_imscp.conf', 'php_fpm_imscp.load' ) {
        next unless -f "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/$_";
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/$_" )->delFile();
        return $rs if $rs;
    }

    if ( -d $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'} ) {
        $rs = execute(
            "rm -f $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'}/*/php5-fastcgi-starter", \ my $stdout, \ my $stderr
        );
        debug( $stdout ) if $stdout;
        error( $stderr || 'Unknown error' ) if $rs;
        return $rs if $rs;
    }

    for ( '/var/log/apache2/backup', '/var/log/apache2/users', '/var/www/scoreboards' ) {
        iMSCP::Dir->new( dirname => $_ )->remove();
    }

    if ( -f "$self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'}/master.conf" ) {
        $rs = iMSCP::File->new(
            filename => "$self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'}/master.conf"
        )->delFile();
        return $rs if $rs;
    }

    $rs = execute( "rm -f $main::imscpConfig{'USER_WEB_DIR'}/*/logs/*.log", \ my $stdout, \ my $stderr );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    return $rs if $rs;

    #
    ## Cleanup and disable unused PHP versions/SAPIs
    #

    if ( -f "$main::imscpConfig{'LOGROTATE_CONF_DIR'}/php5-fpm" ) {
        $rs = iMSCP::File->new( filename => "$main::imscpConfig{'LOGROTATE_CONF_DIR'}/php5-fpm" )->delFile();
        return $rs if $rs;
    }

    iMSCP::Dir->new( dirname => '/etc/php5' )->remove();

    # Some of PHP individual packages install their INI file once for all build
    # variants, including for those not installed yet. Therefore, removing
    # configuration directory for unused build variants is a mistake because
    # when switching to one of them, INI files from individual packages won't
    # be reinstalled.
    # See https://github.com/oerdnj/deb.sury.org/issues/660
    #for(grep !/^$self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}$/,
    #    glob dirname($self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}).'/*'
    #) {
    #    iMSCP::Dir->new( dirname => $_ )->remove( );
    #}

    # CGI
    iMSCP::Dir->new( dirname => $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'} )->remove();

    $self->{'eventManager'}->trigger( 'afterHttpdCleanup' );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
