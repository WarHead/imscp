=head1 NAME

 Package::FrontEnd::Installer - i-MSCP FrontEnd package installer

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2019 by Laurent Declercq <l.declercq@nuxwin.com>
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

package Package::FrontEnd::Installer;

use strict;
use warnings;
use File::Basename;
use iMSCP::Boolean;
use iMSCP::Crypt qw/ ALNUM apr1MD5 randomStr /;
use iMSCP::Database '$DATABASE';
use iMSCP::Debug qw/ debug error getMessageByType /;
use iMSCP::Dialog::InputValidation;
use iMSCP::Dir;
use iMSCP::Execute 'execute';
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Net;
use iMSCP::OpenSSL;
use iMSCP::ProgramFinder;
use iMSCP::Service;
use iMSCP::SystemUser;
use iMSCP::TemplateParser qw/ getBloc replaceBloc /;
use Net::LibIDN qw/ idn_to_ascii idn_to_unicode /;
use Package::FrontEnd;
use Servers::named;
use Servers::mta;
use Servers::httpd;
use Try::Tiny;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP FrontEnd package installer.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners( \%em )

 Register setup event listeners

 Param iMSCP::EventManager \%em
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ( $self, $em ) = @_;

    $em->register( 'beforeSetupDialog', sub {
        push @{ $_[0] },
            sub { $self->askMasterAdminCredentials( @_ ) },
            sub { $self->askMasterAdminEmail( @_ ) },
            sub { $self->askDomain( @_ ) },
            sub { $self->askSsl( @_ ) },
            sub { $self->askHttpPorts( @_ ) };
        0;
    } );
}

=item askMasterAdminCredentials( \%dialog )

 Ask for master administrator credentials

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askMasterAdminCredentials
{
    my ( undef, $dialog ) = @_;

    my ( $username, $password ) = ( '', '' );
    my $hasDatabase = try {
        my $dbName = ::setupGetQuestion( 'DATABASE_NAME' );
        my $db = iMSCP::Database->factory();
        $db->isDatabase( $dbName ) && $db->databaseHasTables( $dbName, qw/ server_ips user_gui_props reseller_props / );
    };

    if ( iMSCP::Getopt->preseed ) {
        $username = ::setupGetQuestion( 'ADMIN_LOGIN_NAME' );
        $password = ::setupGetQuestion( 'ADMIN_PASSWORD' );
    } elsif ( $hasDatabase ) {
        return 1 unless try {
            ( $username, $password ) = @{ iMSCP::Database->factory()->getConnector()->run( fixup => sub {
                $_->selectrow_arrayref( "SELECT admin_name, admin_pass FROM admin WHERE created_by = 0 AND admin_type = 'admin'" );
            } ) // [ '', '' ] };
            TRUE;
        } catch {
            error( $_ );
            FALSE;
        };
    }

    ::setupSetQuestion( 'ADMIN_OLD_LOGIN_NAME', $username );

    if ( iMSCP::Getopt->reconfigure =~ /^(?:admin|admin_credentials|all|forced)$/ || !isValidUsername( $username ) || $password eq '' ) {
        $password = '';
        my ( $rs, $msg ) = ( 0, '' );

        do {
            ( $rs, $username ) = $dialog->inputbox( <<"EOF", $username || 'admin' );

Please enter a username for the master administrator:$msg
EOF
            $msg = '';
            if ( !isValidUsername( $username ) ) {
                $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
            } elsif ( $hasDatabase ) {
                return 1 unless try {
                    $msg = '\n\n\\Z1This username is not available.\\Zn\n\nPlease try again:' unless iMSCP::Database->factory()->getConnector()->run(
                        fixup => sub {
                            $_->selectrow_hashref( 'SELECT 1 FROM admin WHERE admin_name = ? AND created_by <> 0', undef, $username );
                        } );
                    TRUE;
                } catch {
                    error( $_ );
                    FALSE;
                };
            }
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;

        do {
            ( $rs, $password ) = $dialog->inputbox( <<"EOF", randomStr( 16, ALNUM ));

Please enter a password for the master administrator:$msg
EOF
            $msg = isValidPassword( $password ) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    } else {
        $password = '' unless iMSCP::Getopt->preseed
    }

    ::setupSetQuestion( 'ADMIN_LOGIN_NAME', $username );
    ::setupSetQuestion( 'ADMIN_PASSWORD', $password );
    0;
}

=item askMasterAdminEmail( \%dialog )

 Ask for master administrator email address

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askMasterAdminEmail
{
    my ( undef, $dialog ) = @_;

    my $email = ::setupGetQuestion( 'DEFAULT_ADMIN_ADDRESS' );

    if ( iMSCP::Getopt->reconfigure =~ /^(?:admin|admin_email|all|forced)$/ || !isValidEmail( $email ) ) {
        my ( $rs, $msg ) = ( 0, '' );
        do {
            ( $rs, $email ) = $dialog->inputbox( <<"EOF", $email );

Please enter an email address for the master administrator:$msg
EOF
            $msg = isValidEmail( $email ) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    }

    ::setupSetQuestion( 'DEFAULT_ADMIN_ADDRESS', $email );
    0;
}

=item askDomain( \%dialog )

 Show for frontEnd domain name

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askDomain
{
    my ( undef, $dialog ) = @_;

    my $domainName = ::setupGetQuestion( 'BASE_SERVER_VHOST' );

    if ( iMSCP::Getopt->reconfigure =~ /^(?:panel|panel_hostname|hostnames|all|forced)$/ || !isValidDomain( $domainName ) ) {
        unless ( $domainName ) {
            my @domainLabels = split /\./, ::setupGetQuestion( 'SERVER_HOSTNAME' );
            $domainName = 'panel.' . join( '.', @domainLabels[1 .. $#domainLabels] );
        }

        $domainName = idn_to_unicode( $domainName, 'utf-8' );
        my ( $rs, $msg ) = ( 0, '' );
        do {
            ( $rs, $domainName ) = $dialog->inputbox( <<"EOF", $domainName, 'utf-8' );

Please enter a domain name for the control panel:$msg
EOF
            $msg = isValidDomain( $domainName ) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    }

    ::setupSetQuestion( 'BASE_SERVER_VHOST', idn_to_ascii( $domainName, 'utf-8' ));
    0;
}

=item askSsl( \%dialog )

 Ask for frontEnd SSL certificate

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askSsl
{
    my ( undef, $dialog ) = @_;

    my $domainName = ::setupGetQuestion( 'BASE_SERVER_VHOST' );
    my $domainNameUnicode = idn_to_unicode( $domainName, 'utf-8' );
    my $sslEnabled = ::setupGetQuestion( 'PANEL_SSL_ENABLED' );
    my $selfSignedCertificate = ::setupGetQuestion( 'PANEL_SSL_SELFSIGNED_CERTIFICATE', 'no' );
    my $privateKeyPath = ::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PATH', '/root' );
    my $passphrase = ::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PASSPHRASE' );
    my $certificatePath = ::setupGetQuestion( 'PANEL_SSL_CERTIFICATE_PATH', '/root' );
    my $caBundlePath = ::setupGetQuestion( 'PANEL_SSL_CA_BUNDLE_PATH', '/root' );
    my $baseServerVhostPrefix = ::setupGetQuestion( 'BASE_SERVER_VHOST_PREFIX', 'http://' );
    my $openSSL = iMSCP::OpenSSL->new();

    if ( iMSCP::Getopt->reconfigure =~ /^(?:panel|panel_ssl|ssl|all|forced)$/ || $sslEnabled !~ /^(?:yes|no)$/
        || ( $sslEnabled eq 'yes' && iMSCP::Getopt->reconfigure =~ /^(?:panel_hostname|hostnames)$/ )
    ) {
        my $rs = $dialog->yesno( <<'EOF', $sslEnabled eq 'no' ? 1 : 0 );

Do you want to enable SSL for the control panel?
EOF
        if ( $rs == 0 ) {
            $sslEnabled = 'yes';
            $rs = $dialog->yesno( <<"EOF", $selfSignedCertificate eq 'no' ? 1 : 0 );

Do you have a SSL certificate for the $domainNameUnicode domain?
EOF
            if ( $rs == 0 ) {
                my $msg = '';

                do {
                    $dialog->msgbox( <<'EOF' );

$msg
Please select your private key in next dialog.
EOF
                    do {
                        ( $rs, $privateKeyPath ) = $dialog->fselect( $privateKeyPath );
                    } while $rs < 30 && !( $privateKeyPath && -f $privateKeyPath );
                    return $rs if $rs >= 30;

                    ( $rs, $passphrase ) = $dialog->passwordbox( <<'EOF', $passphrase );

Please enter the passphrase for your private key if any:
EOF
                    return $rs if $rs >= 30;

                    $openSSL->{'private_key_container_path'} = $privateKeyPath;
                    $openSSL->{'private_key_passphrase'} = $passphrase;

                    $msg = '';
                    if ( $openSSL->validatePrivateKey() ) {
                        getMessageByType( 'error', { amount => 1, remove => TRUE } );
                        $msg = "\n\\Z1Invalid private key or passphrase.\\Zn\n\nPlease try again.";
                    }
                } while $rs < 30 && $msg;
                return $rs if $rs >= 30;

                $rs = $dialog->yesno( <<'EOF' );

Do you have a SSL CA Bundle?
EOF
                if ( $rs == 0 ) {
                    do {
                        ( $rs, $caBundlePath ) = $dialog->fselect( $caBundlePath );
                    } while $rs < 30 && !( $caBundlePath && -f $caBundlePath );
                    return $rs if $rs >= 30;

                    $openSSL->{'ca_bundle_container_path'} = $caBundlePath;
                } else {
                    $openSSL->{'ca_bundle_container_path'} = '';
                }

                $dialog->msgbox( <<'EOF' );

Please select your SSL certificate in next dialog.
EOF
                $rs = 1;
                do {
                    $dialog->msgbox( <<"EOF" ) unless $rs;
                    
\\Z1Invalid SSL certificate.\\Zn

Please try again.
EOF
                    do {
                        ( $rs, $certificatePath ) = $dialog->fselect( $certificatePath );
                    } while $rs < 30 && !( $certificatePath && -f $certificatePath );
                    return $rs if $rs >= 30;

                    getMessageByType( 'error', { amount => 1, remove => TRUE } );
                    $openSSL->{'certificate_container_path'} = $certificatePath;
                } while $rs < 30 && $openSSL->validateCertificate();
                return $rs if $rs >= 30;
            } else {
                $selfSignedCertificate = 'yes';
            }

            if ( $sslEnabled eq 'yes' ) {
                ( $rs, $baseServerVhostPrefix ) = $dialog->radiolist(
                    <<'EOF', [ 'https', 'http' ], $baseServerVhostPrefix eq 'https://' ? 'https' : 'http' );

Please choose the default HTTP access mode for the control panel:
EOF
                $baseServerVhostPrefix .= '://'
            }
        } else {
            $sslEnabled = 'no';
        }
    } elsif ( $sslEnabled eq 'yes' && !iMSCP::Getopt->preseed ) {
        $openSSL->{'private_key_container_path'} = "$::imscpConfig{'CONF_DIR'}/$domainName.pem";
        $openSSL->{'ca_bundle_container_path'} = "$::imscpConfig{'CONF_DIR'}/$domainName.pem";
        $openSSL->{'certificate_container_path'} = "$::imscpConfig{'CONF_DIR'}/$domainName.pem";

        if ( $openSSL->validateCertificateChain() ) {
            getMessageByType( 'error', { amount => 1, remove => TRUE } );
            $dialog->msgbox( <<'EOF' );

Your SSL certificate for the control panel is missing or invalid.
EOF
            ::setupSetQuestion( 'PANEL_SSL_ENABLED', '' );
            goto &{ askSsl };
        }

        # In case the certificate is valid, we skip SSL setup process
        ::setupSetQuestion( 'PANEL_SSL_SETUP', 'no' );
    }

    ::setupSetQuestion( 'PANEL_SSL_ENABLED', $sslEnabled );
    ::setupSetQuestion( 'PANEL_SSL_SELFSIGNED_CERTIFICATE', $selfSignedCertificate );
    ::setupSetQuestion( 'PANEL_SSL_PRIVATE_KEY_PATH', $privateKeyPath );
    ::setupSetQuestion( 'PANEL_SSL_PRIVATE_KEY_PASSPHRASE', $passphrase );
    ::setupSetQuestion( 'PANEL_SSL_CERTIFICATE_PATH', $certificatePath );
    ::setupSetQuestion( 'PANEL_SSL_CA_BUNDLE_PATH', $caBundlePath );
    ::setupSetQuestion( 'BASE_SERVER_VHOST_PREFIX', $sslEnabled eq 'yes' ? $baseServerVhostPrefix : 'http://' );
    0;
}

=item askHttpPorts( \%dialog )

 Ask for frontEnd http ports

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askHttpPorts
{
    my ( undef, $dialog ) = @_;

    my $httpPort = ::setupGetQuestion( 'BASE_SERVER_VHOST_HTTP_PORT' );
    my $httpsPort = ::setupGetQuestion( 'BASE_SERVER_VHOST_HTTPS_PORT' );
    my $ssl = ::setupGetQuestion( 'PANEL_SSL_ENABLED' );
    my ( $rs, $msg ) = ( 0, '' );

    if ( iMSCP::Getopt->reconfigure =~ /^(?:panel|panel_ports|all|forced)$/ || !isNumber( $httpPort ) || !isNumberInRange( $httpPort, 1025, 65535 )
        || !isStringNotInList( $httpPort, $httpsPort )
    ) {
        do {
            ( $rs, $httpPort ) = $dialog->inputbox( <<"EOF", $httpPort ? $httpPort : 8880 );

Please enter the http port for the control panel:$msg
EOF
            $msg = '';
            if ( !isNumber( $httpPort ) || !isNumberInRange( $httpPort, 1025, 65535 ) || !isStringNotInList( $httpPort, $httpsPort ) ) {
                $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
            }
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    }

    ::setupSetQuestion( 'BASE_SERVER_VHOST_HTTP_PORT', $httpPort );

    if ( $ssl eq 'yes' ) {
        if ( iMSCP::Getopt->reconfigure =~ /^(?:panel|panel_ports|all|forced)$/ || !isNumber( $httpsPort )
            || !isNumberInRange( $httpsPort, 1025, 65535 ) || !isStringNotInList( $httpsPort, $httpPort )
        ) {
            do {
                ( $rs, $httpsPort ) = $dialog->inputbox( <<"EOF", $httpsPort ? $httpsPort : 8443 );

Please enter the https port for the control panel:$msg
EOF
                $msg = '';
                if ( !isNumber( $httpsPort ) || !isNumberInRange( $httpsPort, 1025, 65535 ) || !isStringNotInList( $httpsPort, $httpPort ) ) {
                    $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
                }
            } while $rs < 30 && $msg;
            return $rs if $rs >= 30;
        }
    } else {
        $httpsPort ||= 8443;
    }

    ::setupSetQuestion( 'BASE_SERVER_VHOST_HTTPS_PORT', $httpsPort );
    0;
}

=item install( )

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ( $self ) = @_;

    my $rs = $self->_setupMasterAdmin();
    $rs ||= $self->_setupSsl();
    $rs ||= $self->_setHttpdVersion();
    $rs ||= $self->_addMasterWebUser();
    $rs ||= $self->_makeDirs();
    $rs ||= $self->_copyPhpBinary();
    $rs ||= $self->_buildPhpConfig();
    $rs ||= $self->_buildHttpdConfig();
    $rs ||= $self->_deleteDnsZone();
    $rs ||= $self->_addDnsZone();
    $rs ||= $self->_cleanup();
}

=item dpkgPostInvokeTasks( )

 Process dpkg post-invoke tasks

 See #IP-1641 for further details.

 Return int 0 on success, other on failure

=cut

sub dpkgPostInvokeTasks
{
    my ( $self ) = @_;

    try {
        if ( -f '/usr/local/sbin/imscp_panel' ) {
            unless ( -f $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} ) {
                # Cover case where administrator removed the package
                # That should never occurs but...
                my $rs = $self->{'frontend'}->stop();
                $rs ||= iMSCP::File->new( filename => '/usr/local/sbin/imscp_panel' )->delFile();
                return $rs;
            }

            my $v1 = $self->_getFullPhpVersionFor( $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} );
            my $v2 = $self->_getFullPhpVersionFor( '/usr/local/sbin/imscp_panel' );
            if ( $v1 eq $v2 ) {
                debug( sprintf( "i-MSCP frontEnd PHP-FPM binary is up-to-date: %s", $v2 ));
                return 0;
            }

            debug( sprintf( "Updating i-MSCP frontEnd PHP-FPM binary from version %s to version %s", $v2, $v1 ));
        }

        my $rs = $self->_copyPhpBinary();
        return $rs if $rs || !-f '/usr/local/etc/imscp_panel/php-fpm.conf';

        $self->{'frontend'}->restart();
    } catch {
        error( $_ );
        1;
    };
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Package::FrontEnd::Installer

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'frontend'} = Package::FrontEnd->getInstance();
    $self->{'phpConfig'} = Servers::httpd->factory()->{'phpConfig'};
    $self->{'eventManager'} = $self->{'frontend'}->{'eventManager'};
    $self->{'cfgDir'} = $self->{'frontend'}->{'cfgDir'};
    $self->{'config'} = $self->{'frontend'}->{'config'};
    $self;
}

=item _setupMasterAdmin( )

 Setup master administrator

 Return int 0 on success, other on failure

=cut

sub _setupMasterAdmin
{
    try {
        my $login = ::setupGetQuestion( 'ADMIN_LOGIN_NAME' );
        my $loginOld = ::setupGetQuestion( 'ADMIN_OLD_LOGIN_NAME' );
        my $password = ::setupGetQuestion( 'ADMIN_PASSWORD' );
        my $email = ::setupGetQuestion( 'DEFAULT_ADMIN_ADDRESS' );

        return 0 if $password eq '';

        $password = apr1MD5( $password );

        local $DATABASE = ::setupGetQuestion( 'DATABASE_NAME' );

        my ( $adminID ) = @{ iMSCP::Database->factory()->getConnector()->run( fixup => sub {
            $_->selectcol_arrayref( "SELECT admin_id FROM admin WHERE admin_name = ?", undef, $loginOld );
        } ) };

        if ( $adminID ) {
            iMSCP::Database->factory()->getConnector()->run( fixup => sub {
                $_->do( 'UPDATE admin SET admin_name = ?, admin_pass = ?, email = ? WHERE admin_id = ?', undef, $login, $password, $email, $adminID );
            } );
        } else {
            iMSCP::Database->factory()->getConnector()->txn( fixup => sub {
                $_->do(
                    "INSERT INTO admin (admin_name, admin_pass, admin_type, email) VALUES (?, ?, 'admin', ?)", undef, $login, $password, $email
                );
                $_->do( 'INSERT INTO user_gui_props SET user_id = LAST_INSERT_ID()' );
            } );
        }

        0;
    } catch {
        error( $_ );
        1;
    };
}

=item _setupSsl( )

 Setup SSL

 Return int 0 on success, other on failure

=cut

sub _setupSsl
{
    try {
        my $sslEnabled = ::setupGetQuestion( 'PANEL_SSL_ENABLED' );
        my $oldCertificate = $::imscpOldConfig{'BASE_SERVER_VHOST'};
        my $domainName = ::setupGetQuestion( 'BASE_SERVER_VHOST' );

        # Remove old certificate if any (handle case where panel hostname has been changed)
        if ( $oldCertificate ne '' && $oldCertificate ne "$domainName.pem" && -f "$::imscpConfig{'CONF_DIR'}/$oldCertificate" ) {
            my $rs = iMSCP::File->new( filename => "$::imscpConfig{'CONF_DIR'}/$oldCertificate" )->delFile();
            return $rs if $rs;
        }

        if ( $sslEnabled eq 'no' || ::setupGetQuestion( 'PANEL_SSL_SETUP', 'yes' ) eq 'no' ) {
            if ( $sslEnabled eq 'no' && -f "$::imscpConfig{'CONF_DIR'}/$domainName.pem" ) {
                my $rs = iMSCP::File->new( filename => "$::imscpConfig{'CONF_DIR'}/$domainName.pem" )->delFile();
                return $rs if $rs;
            }

            return 0;
        }

        if ( ::setupGetQuestion( 'PANEL_SSL_SELFSIGNED_CERTIFICATE' ) eq 'yes' ) {
            return iMSCP::OpenSSL->new(
                certificate_chains_storage_dir => $::imscpConfig{'CONF_DIR'},
                certificate_chain_name         => $domainName
            )->createSelfSignedCertificate( {
                common_name => $domainName,
                email       => ::setupGetQuestion( 'DEFAULT_ADMIN_ADDRESS' )
            } );
        }

        iMSCP::OpenSSL->new(
            certificate_chains_storage_dir => $::imscpConfig{'CONF_DIR'},
            certificate_chain_name         => $domainName,
            private_key_container_path     => ::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PATH' ),
            private_key_passphrase         => ::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PASSPHRASE' ),
            certificate_container_path     => ::setupGetQuestion( 'PANEL_SSL_CERTIFICATE_PATH' ),
            ca_bundle_container_path       => ::setupGetQuestion( 'PANEL_SSL_CA_BUNDLE_PATH' )
        )->createCertificateChain();
    } catch {
        error( $_ );
        1;
    };
}

=item _setHttpdVersion( )

 Set httpd version

 Return int 0 on success, other on failure

=cut

sub _setHttpdVersion( )
{
    my ( $self ) = @_;

    my $rs = execute( [ 'nginx', '-v' ], \my $stdout, \my $stderr );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    return $rs if $rs;

    if ( $stderr !~ m%nginx/([\d.]+)% ) {
        error( "Couldn't guess Nginx version" );
        return 1;
    }

    $self->{'config'}->{'HTTPD_VERSION'} = $1;
    debug( sprintf( 'Nginx version set to: %s', $1 ));
    0;
}

=item _addMasterWebUser( )

 Add master Web user

 Return int 0 on success, other on failure

=cut

sub _addMasterWebUser
{
    my ( $self ) = @_;

    try {
        my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndAddUser' );
        return $rs if $rs;

        my $ug = $::imscpConfig{'SYSTEM_USER_PREFIX'} . $::imscpConfig{'SYSTEM_USER_MIN_UID'};

        local $DATABASE = ::setupGetQuestion( 'DATABASE_NAME' );

        my $row = iMSCP::Database->factory()->getConnector()->run( fixup => sub {
            $_->selectrow_hashref(
                "SELECT admin_sys_name, admin_sys_uid, admin_sys_gname FROM admin WHERE admin_type = 'admin' AND created_by = 0 LIMIT 1"
            );
        } );
        $row or die( "Couldn't find master administrator user in database" );

        my ( $oldUser, $uid, $gid ) = $row->{'admin_sys_uid'} && $row->{'admin_sys_uid'} ne '0' ? ( getpwuid( $row->{'admin_sys_uid'} ) )[0, 2, 3] : ();

        $rs = iMSCP::SystemUser->new(
            username       => $oldUser,
            comment        => 'i-MSCP Control Panel Web User',
            home           => $::imscpConfig{'GUI_ROOT_DIR'},
            skipCreateHome => TRUE
        )->addSystemUser( $ug, $ug );
        return $rs if $rs;

        ( $uid, $gid ) = ( getpwnam( $ug ) )[2, 3];

        iMSCP::Database->factory()->getConnector()->run( fixup => sub {
            $_->do(
                "UPDATE admin SET admin_sys_name = ?, admin_sys_uid = ?, admin_sys_gname = ?, admin_sys_gid = ? WHERE admin_type = 'admin'",
                undef, $ug, $uid, $ug, $gid
            );
        } );

        $rs = iMSCP::SystemUser->new( username => $ug )->addToGroup( $::imscpConfig{'IMSCP_GROUP'} );
        $rs = iMSCP::SystemUser->new( username => $ug )->addToGroup( Servers::mta->factory()->{'config'}->{'MTA_MAILBOX_GID_NAME'} );
        $rs ||= iMSCP::SystemUser->new( username => $self->{'config'}->{'HTTPD_USER'} )->addToGroup( $ug );
        $rs ||= $self->{'eventManager'}->trigger( 'afterFrontEndAddUser' );
    } catch {
        error( $_ );
        1;
    };
}

=item _makeDirs( )

 Create directories

 Return int 0 on success, other on failure

=cut

sub _makeDirs
{
    my ( $self ) = @_;

    try {
        my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndMakeDirs' );
        return $rs if $rs;

        my $nginxTmpDir = $self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'};
        $nginxTmpDir = $self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'} unless -d $nginxTmpDir;

        # Force re-creation of cache directory tree (needed to prevent any
        # permissions problem from an old installation). See #IP-1530
        iMSCP::Dir->new( dirname => $nginxTmpDir )->remove();

        for my $dir ( [ $nginxTmpDir, $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}, 0755 ],
            [ $self->{'config'}->{'HTTPD_CONF_DIR'}, $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}, 0755 ],
            [ $self->{'config'}->{'HTTPD_LOG_DIR'}, $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}, 0755 ],
            [ $self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}, $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}, 0755 ],
            [ $self->{'config'}->{'HTTPD_SITES_ENABLED_DIR'}, $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'}, 0755 ]
        ) {
            iMSCP::Dir->new( dirname => $dir->[0] )->make( {
                user  => $dir->[1],
                group => $dir->[2],
                mode  => $dir->[3]
            } );
        }

        if ( iMSCP::Service->getInstance->isSystemd() ) {
            iMSCP::Dir->new( dirname => '/run/imscp' )->make( {
                user  => $self->{'config'}->{'HTTPD_USER'},
                group => $self->{'config'}->{'HTTPD_GROUP'},
                mode  => 0755
            } );
        }

        $self->{'eventManager'}->trigger( 'afterFrontEndMakeDirs' );
    } catch {
        error( $_ );
        1;
    };
}

=item _copyPhpBinary( )

 Copy system PHP-FPM binary for imscp_panel service

 Return int 0 on success, other on failure

=cut

sub _copyPhpBinary
{
    my ( $self ) = @_;

    unless ( length $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} ) {
        error( "PHP 'PHP_FPM_BIN_PATH' configuration parameter is not set." );
        return 1;
    }

    iMSCP::File->new( filename => $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} )->copyFile( '/usr/local/sbin/imscp_panel', { preserve => 'yes' } );
}

=item _buildPhpConfig( )

 Build PHP configuration

 Return int 0 on success, other on failure

=cut

sub _buildPhpConfig
{
    my ( $self ) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndBuildPhpConfig' );
    return $rs if $rs;

    my $user = $::imscpConfig{'SYSTEM_USER_PREFIX'} . $::imscpConfig{'SYSTEM_USER_MIN_UID'};
    my $group = $::imscpConfig{'SYSTEM_USER_PREFIX'} . $::imscpConfig{'SYSTEM_USER_MIN_UID'};

    $rs = $self->{'frontend'}->buildConfFile( "$self->{'cfgDir'}/php-fpm.conf",
        {
            CHKROOTKIT_LOG            => $::imscpConfig{'CHKROOTKIT_LOG'},
            CONF_DIR                  => $::imscpConfig{'CONF_DIR'},
            DOMAIN                    => ::setupGetQuestion( 'BASE_SERVER_VHOST' ),
            DISTRO_OPENSSL_CNF        => $::imscpConfig{'DISTRO_OPENSSL_CNF'},
            DISTRO_CA_BUNDLE          => $::imscpConfig{'DISTRO_CA_BUNDLE'},
            FRONTEND_FCGI_CHILDREN    => $self->{'config'}->{'FRONTEND_FCGI_CHILDREN'},
            FRONTEND_FCGI_MAX_REQUEST => $self->{'config'}->{'FRONTEND_FCGI_MAX_REQUEST'},
            FRONTEND_GROUP            => $group,
            FRONTEND_USER             => $user,
            HOME_DIR                  => $::imscpConfig{'GUI_ROOT_DIR'},
            MTA_VIRTUAL_MAIL_DIR      => Servers::mta->factory()->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'},
            PEAR_DIR                  => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
            RKHUNTER_LOG              => $::imscpConfig{'RKHUNTER_LOG'},
            TIMEZONE                  => ::setupGetQuestion( 'TIMEZONE' ),
            WEB_DIR                   => $::imscpConfig{'GUI_ROOT_DIR'}
        },
        {
            destination => '/usr/local/etc/imscp_panel/php-fpm.conf',
            user        => $::imscpConfig{'ROOT_USER'},
            group       => $::imscpConfig{'ROOT_GROUP'},
            mode        => 0640
        }
    );
    $rs ||= $self->{'frontend'}->buildConfFile( "$self->{'cfgDir'}/php.ini",
        {

            PEAR_DIR => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
            TIMEZONE => ::setupGetQuestion( 'TIMEZONE' )
        },
        {
            destination => '/usr/local/etc/imscp_panel/php.ini',
            user        => $::imscpConfig{'ROOT_USER'},
            group       => $::imscpConfig{'ROOT_GROUP'},
            mode        => 0640,
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterFrontEndBuildPhpConfig' );
}

=item _buildHttpdConfig( )

 Build httpd configuration

 Return int 0 on success, other on failure

=cut

sub _buildHttpdConfig
{
    my ( $self ) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndBuildHttpdConfig' );
    return $rs if $rs;

    # Build main nginx configuration file
    $rs = $self->{'frontend'}->buildConfFile( "$self->{'cfgDir'}/nginx.nginx",
        {
            HTTPD_USER               => $self->{'config'}->{'HTTPD_USER'},
            HTTPD_WORKER_PROCESSES   => $self->{'config'}->{'HTTPD_WORKER_PROCESSES'},
            HTTPD_WORKER_CONNECTIONS => $self->{'config'}->{'HTTPD_WORKER_CONNECTIONS'},
            HTTPD_RLIMIT_NOFILE      => $self->{'config'}->{'HTTPD_RLIMIT_NOFILE'},
            HTTPD_LOG_DIR            => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_PID_FILE           => $self->{'config'}->{'HTTPD_PID_FILE'},
            HTTPD_CONF_DIR           => $self->{'config'}->{'HTTPD_CONF_DIR'},
            HTTPD_LOG_DIR            => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_SITES_ENABLED_DIR  => $self->{'config'}->{'HTTPD_SITES_ENABLED_DIR'}
        },
        {
            destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/nginx.conf",
            user        => $::imscpConfig{'ROOT_USER'},
            group       => $::imscpConfig{'ROOT_GROUP'},
            mode        => 0644
        }
    );

    # Build FastCGI configuration file
    $rs = $self->{'frontend'}->buildConfFile( "$self->{'cfgDir'}/imscp_fastcgi.nginx", {}, {
        destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/imscp_fastcgi.conf",
        user        => $::imscpConfig{'ROOT_USER'},
        group       => $::imscpConfig{'ROOT_GROUP'},
        mode        => 0644
    } );

    # Build PHP backend configuration file
    $rs = $self->{'frontend'}->buildConfFile( "$self->{'cfgDir'}/imscp_php.nginx", {}, {
        destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/imscp_php.conf",
        user        => $::imscpConfig{'ROOT_USER'},
        group       => $::imscpConfig{'ROOT_GROUP'},
        mode        => 0644
    } );
    $rs ||= $self->{'eventManager'}->trigger( 'afterFrontEndBuildHttpdConfig' );
    $rs ||= $self->{'eventManager'}->trigger( 'beforeFrontEndBuildHttpdVhosts' );
    return $rs if $rs;

    # Build frontEnd site files
    my $baseServerIpVersion = iMSCP::Net->getInstance()->getAddrVersion( ::setupGetQuestion( 'BASE_SERVER_IP' ));
    my $httpsPort = ::setupGetQuestion( 'BASE_SERVER_VHOST_HTTPS_PORT' );
    my $tplVars = {
        BASE_SERVER_VHOST            => ::setupGetQuestion( 'BASE_SERVER_VHOST' ),
        BASE_SERVER_IP               => $baseServerIpVersion eq 'ipv4'
            ? ::setupGetQuestion( 'BASE_SERVER_IP' ) =~ s/^\Q0.0.0.0\E$/*/r : '[' . ::setupGetQuestion( 'BASE_SERVER_IP' ) . ']',
        BASE_SERVER_VHOST_HTTP_PORT  => ::setupGetQuestion( 'BASE_SERVER_VHOST_HTTP_PORT' ),
        BASE_SERVER_VHOST_HTTPS_PORT => $httpsPort,
        WEB_DIR                      => $::imscpConfig{'GUI_ROOT_DIR'},
        CONF_DIR                     => $::imscpConfig{'CONF_DIR'},
        PLUGINS_DIR                  => $::imscpConfig{'PLUGINS_DIR'}
    };

    $rs = $self->{'frontend'}->disableSites( 'default', '00_master.conf', '00_master_ssl.conf' );
    $rs ||= $self->{'eventManager'}->register( 'beforeFrontEndBuildConf', sub {
        my ( $cfgTpl, $tplName ) = @_;

        return 0 unless grep ($_ eq $tplName, '00_master.nginx', '00_master_ssl.nginx');

        if ( $baseServerIpVersion eq 'ipv6' || !::setupGetQuestion( 'IPV6_SUPPORT' ) ) {
            ${ $cfgTpl } = replaceBloc( '# SECTION IPv6 BEGIN.', '# SECTION IPv6 END.', '', ${ $cfgTpl } );
        }

        return 0 unless $tplName eq '00_master.nginx' && ::setupGetQuestion( 'BASE_SERVER_VHOST_PREFIX' ) eq 'https://';

        ${ $cfgTpl } = replaceBloc(
            "# SECTION custom BEGIN.\n",
            "# SECTION custom END.\n",
            "    # SECTION custom BEGIN.\n" .
                getBloc( "# SECTION custom BEGIN.\n", "# SECTION custom END.\n", ${ $cfgTpl } )
                . <<'EOF'
    return 302 https://{BASE_SERVER_VHOST}:{BASE_SERVER_VHOST_HTTPS_PORT}$request_uri;
EOF
                . "    # SECTION custom END.\n",
            ${ $cfgTpl }
        );

        0;
    } );
    $rs ||= $self->{'frontend'}->buildConfFile( '00_master.nginx', $tplVars, {
        destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master.conf",
        user        => $::imscpConfig{'ROOT_USER'},
        group       => $::imscpConfig{'ROOT_GROUP'},
        mode        => 0644
    } );
    $rs ||= $self->{'frontend'}->enableSites( '00_master.conf' );
    return $rs if $rs;

    if ( ::setupGetQuestion( 'PANEL_SSL_ENABLED' ) eq 'yes' ) {
        $rs ||= $self->{'frontend'}->buildConfFile( '00_master_ssl.nginx', $tplVars, {
            destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf",
            user        => $::imscpConfig{'ROOT_USER'},
            group       => $::imscpConfig{'ROOT_GROUP'},
            mode        => 0644
        } );
        $rs ||= $self->{'frontend'}->enableSites( '00_master_ssl.conf' );
        return $rs if $rs;
    } elsif ( -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf" ) {
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf" )->delFile();
        return $rs if $rs;
    }

    if ( -f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf" ) {
        # Nginx package as provided by Nginx Team
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf" )->moveFile(
            "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf.disabled"
        );
        return $rs if $rs;
    }

    $self->{'eventManager'}->trigger( 'afterFrontEndBuildHttpdVhosts' );
}

=item _addDnsZone( )

 Add DNS zone

 Return int 0 on success, other on failure

=cut

sub _addDnsZone
{
    my ( $self ) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeNamedAddMasterZone' );
    $rs ||= Servers::named->factory()->addDmn( {
        BASE_SERVER_VHOST     => ::setupGetQuestion( 'BASE_SERVER_VHOST' ),
        BASE_SERVER_IP        => ::setupGetQuestion( 'BASE_SERVER_IP' ),
        BASE_SERVER_PUBLIC_IP => ::setupGetQuestion( 'BASE_SERVER_PUBLIC_IP' ),
        DOMAIN_NAME           => ::setupGetQuestion( 'BASE_SERVER_VHOST' ),
        DOMAIN_IP             => ::setupGetQuestion( 'BASE_SERVER_IP' ),
        MAIL_ENABLED          => TRUE
    } );
    $rs ||= $self->{'eventManager'}->trigger( 'afterNamedAddMasterZone' );
}

=item _deleteDnsZone( )

 Delete previous DNS zone if needed (i.e. case where BASER_SERVER_VHOST has been modified)

 Return int 0 on success, other on failure

=cut

sub _deleteDnsZone
{
    my ( $self ) = @_;

    return 0 unless $::imscpOldConfig{'BASE_SERVER_VHOST'} && $::imscpOldConfig{'BASE_SERVER_VHOST'} ne ::setupGetQuestion( 'BASE_SERVER_VHOST' );

    my $rs = $self->{'eventManager'}->trigger( 'beforeNamedDeleteMasterZone' );
    $rs ||= Servers::named->factory()->deleteDmn( {
        DOMAIN_NAME    => $::imscpOldConfig{'BASE_SERVER_VHOST'},
        FORCE_DELETION => TRUE
    } );
    $rs ||= $self->{'eventManager'}->trigger( 'afterNamedDeleteMasterZone' );
}

=item _getFullPhpVersionFor( $binary )

 Get full PHP version for the given PHP binary

 Param string $binary PHP binary path
 Return PHP full version on success, die on failure

=cut

sub _getFullPhpVersionFor
{
    my ( undef, $binary ) = @_;

    my ( $stdout, $stderr );
    execute( [ $binary, '-nv' ], \$stdout, \$stderr ) == 0 && $stdout =~ /PHP\s+([^\s]+)/ or die(
        sprintf( "Couldn't retrieve PHP version: %s", $stderr || 'Unknown error' )
    );
    $1;
}

=item _cleanup( )

 Process cleanup tasks

 Return int 0 on success, other on failure

=cut

sub _cleanup
{
    my ( $self ) = @_;

    return 0 unless -f "$self->{'cfgDir'}/frontend.old.data";

    iMSCP::File->new( filename => "$self->{'cfgDir'}/frontend.old.data" )->delFile();
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
