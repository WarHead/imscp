=head1 NAME

 Modules::Alias - i-MSCP domain alias module

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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

package Modules::Alias;

use strict;
use warnings;
use File::Spec;
use iMSCP::Boolean;
use iMSCP::Debug qw/ error getMessageByType /;
use Net::LibIDN 'idn_to_unicode';
use Servers::httpd;
use Try::Tiny;
use parent 'Modules::Abstract';

=head1 DESCRIPTION

 i-MSCP domain alias module.

=head1 PUBLIC METHODS

=over 4

=item getType( )

 Get module type

 Return string Module type

=cut

sub getType
{
    'Dmn';
}

=item process( \%data )

 Process module

 Param hashref \%data Domain alias data
 Return int 0 on success, die on failure

=cut

sub process
{
    my ( $self, $data ) = @_;

    $self->_loadData( $data->{'id'} );

    my @sql;
    if ( $self->{'alias_status'} =~ /^to(?:add|change|enable)$/ ) {
        @sql = (
            'UPDATE domain_aliasses SET alias_status = ? WHERE alias_id = ?', undef,
            ( $self->add() ? getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error' : 'ok' ), $data->{'id'}
        );
    } elsif ( $self->{'alias_status'} eq 'todisable' ) {
        @sql = (
            'UPDATE domain_aliasses SET alias_status = ? WHERE alias_id = ?', undef,
            ( $self->disable() ? getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error' : 'disabled' ), $data->{'id'}
        );
    } elsif ( $self->{'alias_status'} eq 'torestore' ) {
        @sql = (
            'UPDATE domain_aliasses SET alias_status = ? WHERE alias_id = ?', undef,
            ( $self->restore() ? getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error' : 'ok' ), $data->{'id'}
        );
    } else {
        @sql = $self->delete() ? (
            'UPDATE domain_aliasses SET alias_status = ? WHERE alias_id = ?', undef,
            getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error', $data->{'id'}
        ) : ( 'DELETE FROM domain_aliasses WHERE alias_id = ?', undef, $data->{'id'} );
    }

    $self->{'_conn'}->run( fixup => sub { $_->do( @sql ); } );
    0;
}

=item add( )

 Add domain alias

 Schedule change of custom DNS records that belong to this domain alias unless
 there is already a pending task for them. See #IP-1801
 
 Return int 0 on success, other on failure

=cut

sub add
{
    my ( $self ) = @_;

    return $self->SUPER::add() if $self->{'alias_status'} eq 'toadd' || $::execmode eq 'setup';

    return 1 unless try {
        $self->{'_conn'}->run( fixup => sub {
            $_->do(
                "UPDATE domain_dns SET domain_dns_status = 'tochange' WHERE alias_id = ? AND domain_dns_status = 'ok'", undef, $self->{'alias_id'}
            );
        } );
        TRUE;
    } catch {
        error( $_ );
        FALSE;
    };

    $self->SUPER::add();
}

=item disable( )

 Disable domain alias

 Return int 0 on success, other on failure

=cut

sub disable
{
    my ( $self ) = @_;

    return 1 unless try {
        $self->{'_conn'}->run( fixup => sub {
            $_->do(
                "UPDATE subdomain_alias SET subdomain_alias_status = 'todisable' WHERE alias_id = ? AND subdomain_alias_status <> 'todelete'",
                undef,
                $self->{'alias_id'}
            );
        } );
        TRUE;
    } catch {
        error( $_ );
        FALSE;
    };

    $self->SUPER::disable();
}

=back

=head1 PRIVATE METHODS

=over 4

=item _loadData( $aliasId )

 Load data

 Param int $aliasId Domain Alias unique identifier
 Return void, die on failure

=cut

sub _loadData
{
    my ( $self, $aliasId ) = @_;

    my $row = $self->{'_conn'}->run( fixup => sub {
        $_->selectrow_hashref(
            "
                SELECT t1.*,
                    t2.domain_name AS user_home, t2.domain_admin_id, t2.domain_mailacc_limit, t2.domain_php, t2.domain_cgi, t2.web_folder_protection,
                    IFNULL(t3.ip_number, '0.0.0.0') AS ip_number,
                    t4.private_key, t4.certificate, t4.ca_bundle, t4.allow_hsts, t4.hsts_max_age, t4.hsts_include_subdomains,
                    t5.mail_on_domain
                FROM domain_aliasses AS t1
                JOIN domain AS t2 ON (t2.domain_id = t1.domain_id)
                LEFT JOIN server_ips AS t3 ON (t3.ip_id = t1.alias_ip_id)
                LEFT JOIN ssl_certs AS t4 ON(t4.domain_id = t1.alias_id AND t4.domain_type = 'als' AND t4.status = 'ok')
                LEFT JOIN(
                    SELECT sub_id, COUNT(sub_id) AS mail_on_domain FROM mail_users WHERE mail_type LIKE 'alias\\_%' GROUP BY sub_id
                ) AS t5 ON (t5.sub_id = t1.alias_id)
                WHERE t1.alias_id = ?
            ",
            undef, $aliasId
        );
    } );
    $row or die( sprintf( 'Data not found for domain alias (ID %d)', $aliasId ));
    %{ $self } = ( %{ $self }, %{ $row } );
}

=item _getData( $action )

 Data provider method for servers and packages

 Param string $action Action
 Return hashref Reference to a hash containing data, die on failure

=cut

sub _getData
{
    my ( $self, $action ) = @_;

    $self->{'_data'} = do {
        my $httpd = Servers::httpd->factory();
        my $ug = $::imscpConfig{'SYSTEM_USER_PREFIX'} . ( $::imscpConfig{'SYSTEM_USER_MIN_UID'}+$self->{'domain_admin_id'} );
        my $homeDir = File::Spec->canonpath( "$::imscpConfig{'USER_WEB_DIR'}/$self->{'user_home'}" );
        my $webDir = File::Spec->canonpath( "$homeDir/$self->{'alias_mount'}" );
        my $documentRoot = File::Spec->canonpath( "$webDir/$self->{'alias_document_root'}" );
        my $confLevel = $httpd->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} eq 'per_user' ? 'dmn' : 'als';
        my $phpini = $self->{'_conn'}->run( fixup => sub {
            $_->selectrow_hashref(
                'SELECT * FROM php_ini WHERE domain_id = ? AND domain_type = ?', undef,
                ( $confLevel eq 'dmn' ? $self->{'domain_id'} : $self->{'alias_id'} ), $confLevel
            ) || {};
        } );
        my $haveCert = defined $self->{'certificate'} && -f "$::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$self->{'alias_name'}.pem";
        my $allowHSTS = $haveCert && $self->{'allow_hsts'} eq 'on';
        my $hstsMaxAge = $allowHSTS ? $self->{'hsts_max_age'} : 0;
        my $hstsIncludeSubDomains = $allowHSTS && $self->{'hsts_include_subdomains'} eq 'on'
            ? '; includeSubDomains' : ( $allowHSTS ? '' : '; includeSubDomains' );
        {
            STATUS                  => $self->{'alias_status'},
            BASE_SERVER_VHOST       => $::imscpConfig{'BASE_SERVER_VHOST'},
            BASE_SERVER_IP          => $::imscpConfig{'BASE_SERVER_IP'},
            BASE_SERVER_PUBLIC_IP   => $::imscpConfig{'BASE_SERVER_PUBLIC_IP'},
            DOMAIN_ADMIN_ID         => $self->{'domain_admin_id'},
            DOMAIN_ID               => $self->{'alias_id'},
            DOMAIN_NAME             => $self->{'alias_name'},
            DOMAIN_NAME_UNICODE     => idn_to_unicode( $self->{'alias_name'}, 'utf-8' ),
            DOMAIN_IP               => $self->{'ip_number'},
            DOMAIN_TYPE             => 'als',
            PARENT_DOMAIN_NAME      => $self->{'alias_name'},
            ROOT_DOMAIN_NAME        => $self->{'user_home'},
            HOME_DIR                => $homeDir,
            WEB_DIR                 => $webDir,
            MOUNT_POINT             => $self->{'alias_mount'},
            DOCUMENT_ROOT           => $documentRoot,
            SHARED_MOUNT_POINT      => $self->_sharedMountPoint(),
            PEAR_DIR                => $httpd->{'phpConfig'}->{'PHP_PEAR_DIR'},
            TIMEZONE                => $::imscpConfig{'TIMEZONE'},
            USER                    => $ug,
            GROUP                   => $ug,
            PHP_SUPPORT             => $self->{'domain_php'},
            CGI_SUPPORT             => $self->{'domain_cgi'},
            WEB_FOLDER_PROTECTION   => $self->{'web_folder_protection'},
            SSL_SUPPORT             => $haveCert,
            HSTS_SUPPORT            => $allowHSTS,
            HSTS_MAX_AGE            => $hstsMaxAge,
            HSTS_INCLUDE_SUBDOMAINS => $hstsIncludeSubDomains,
            FORWARD                 => $self->{'url_forward'} || 'no',
            FORWARD_TYPE            => $self->{'type_forward'} || '',
            FORWARD_PRESERVE_HOST   => $self->{'host_forward'} || 'Off',
            DISABLE_FUNCTIONS       => $phpini->{'disable_functions'} || '',
            MAX_EXECUTION_TIME      => $phpini->{'max_execution_time'} || 30,
            MAX_INPUT_TIME          => $phpini->{'max_input_time'} || 60,
            MEMORY_LIMIT            => $phpini->{'memory_limit'} || 128,
            ERROR_REPORTING         => $phpini->{'error_reporting'} || 'E_ALL & ~E_DEPRECATED & ~E_STRICT',
            DISPLAY_ERRORS          => $phpini->{'display_errors'} || 'off',
            POST_MAX_SIZE           => $phpini->{'post_max_size'} || 8,
            UPLOAD_MAX_FILESIZE     => $phpini->{'upload_max_filesize'} || 2,
            ALLOW_URL_FOPEN         => $phpini->{'allow_url_fopen'} || 'off',
            PHP_FPM_LISTEN_PORT     => ( $phpini->{'id'} // 1 )-1,
            EXTERNAL_MAIL           => $self->{'external_mail'},
            MAIL_ENABLED            => ( $self->{'external_mail'} eq 'off' && ( $self->{'mail_on_domain'} || $self->{'domain_mailacc_limit'} >= 0 ) )
        }
    } unless %{ $self->{'_data'} };

    $self->{'_data'}->{'ACTION'} = $action;
    $self->{'_data'};
}

=item _sharedMountPoint( )

 Does this domain alias share mount point with another domain?

 Return bool, die on failure

=cut

sub _sharedMountPoint
{
    my ( $self ) = @_;

    my ( $nbSharedMountPoints ) = $self->{'_conn'}->run( fixup => sub {
        my $regexp = "^$self->{'alias_mount'}(/.*|\$)";
        $_->selectrow_array(
            "
                SELECT COUNT(mount_point) AS nb_mount_points FROM (
                    SELECT alias_mount AS mount_point FROM domain_aliasses
                    WHERE alias_id <> ?
                    AND domain_id = ?
                    AND alias_status NOT IN ('todelete', 'ordered')
                    AND alias_mount RLIKE ?
                    UNION ALL
                    SELECT subdomain_mount AS mount_point
                    FROM subdomain
                    WHERE domain_id = ?
                    AND subdomain_status != 'todelete'
                    AND subdomain_mount RLIKE ?
                    UNION ALL
                    SELECT subdomain_alias_mount AS mount_point
                    FROM subdomain_alias
                    WHERE subdomain_alias_status <> 'todelete'
                    AND alias_id IN (SELECT alias_id FROM domain_aliasses WHERE domain_id = ?)
                    AND subdomain_alias_mount RLIKE ?
                ) AS tmp
            ",
            undef, $self->{'alias_id'}, $self->{'domain_id'}, $regexp, $self->{'domain_id'}, $regexp, $self->{'domain_id'}, $regexp
        );
    } );

    ( $nbSharedMountPoints || $self->{'alias_mount'} eq '/' );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
