=head1 NAME

 Modules::User - i-MSCP User module

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

package Modules::User;

use strict;
use warnings;
use iMSCP::Boolean;
use iMSCP::Debug qw/ error getMessageByType /;
use iMSCP::SystemGroup;
use iMSCP::SystemUser;
use Try::Tiny;
use parent 'Modules::Abstract';

=head1 DESCRIPTION

 i-MSCP User module.

=head1 PUBLIC METHODS

=over 4

=item getType( )

 Get module type

 Return string Module type

=cut

sub getType
{
    'User';
}

=item process( \%data )

 Process module

 Param hashref \%data User data
 Return int 0 on success, die on failure

=cut

sub process
{
    my ( $self, $data ) = @_;

    $self->_loadData( $data->{'id'} );

    my @sql;
    if ( $self->{'admin_status'} =~ /^to(?:add|change(?:pwd)?)$/ ) {
        @sql = (
            'UPDATE admin SET admin_status = ? WHERE admin_id = ?', undef,
            ( $self->add() ? getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error' : 'ok' ), $data->{'id'}
        );
    } else {
        @sql = $self->delete() ? (
            'UPDATE admin SET admin_status = ? WHERE admin_id = ?', undef,
            getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error', $data->{'id'}
        ) : ( 'DELETE FROM admin WHERE admin_id = ?', undef, $data->{'id'} );
    }

    $self->{'_conn'}->run( fixup => sub { $_->do( @sql ); } );
    0;
}

=item add( )

 Add user

 Return int 0 on success, other on failure

=cut

sub add
{
    my ( $self ) = @_;

    return $self->SUPER::add() if $self->{'admin_status'} eq 'tochangepwd';

    return 1 unless try {
        my $ug = $::imscpConfig{'SYSTEM_USER_PREFIX'} . ( $::imscpConfig{'SYSTEM_USER_MIN_UID'}+$self->{'admin_id'} );
        my $home = "$::imscpConfig{'USER_WEB_DIR'}/$self->{'admin_name'}";
        my $rs = $self->{'eventManager'}->trigger( 'onBeforeAddImscpUnixUser', $self->{'admin_id'}, $ug, \my $pwd, $home, \my $skel, \my $shell );
        return $rs if $rs;

        my ( $oldUser, $uid, $gid ) = $self->{'admin_sys_uid'} && $self->{'admin_sys_uid'} ne '0'
            ? ( getpwuid( $self->{'admin_sys_uid'} ) )[0, 2, 3] : ();

        $rs = iMSCP::SystemUser->new(
            username     => $oldUser,
            password     => $pwd,
            comment      => 'i-MSCP Web User',
            home         => $home,
            skeletonPath => $skel,
            shell        => $shell
        )->addSystemUser( $ug, $ug );
        return $rs if $rs;

        ( $uid, $gid ) = ( getpwnam( $ug ) )[2, 3];

        $self->{'_conn'}->run( fixup => sub {
            $_->do( 'UPDATE admin SET admin_sys_name = ?, admin_sys_uid = ?, admin_sys_gname = ?, admin_sys_gid = ? WHERE admin_id = ?', undef, $ug,
                $uid, $ug, $gid, $self->{'admin_id'},
            );
        } );
        @{ $self }{ qw/ admin_sys_name admin_sys_uid admin_sys_gname admin_sys_gid / } = ( $ug, $uid, $ug, $gid );
        TRUE;
    } catch {
        error( $_ );
        FALSE;
    };

    $self->SUPER::add();
}

=item delete( )

 Delete user

 Return int 0 on success, other on failure

=cut

sub delete
{
    my ( $self ) = @_;

    try {
        my $ug = $::imscpConfig{'SYSTEM_USER_PREFIX'} . ( $::imscpConfig{'SYSTEM_USER_MIN_UID'}+$self->{'admin_id'} );
        my $rs = $self->{'eventManager'}->trigger( 'onBeforeDeleteImscpUnixUser', $ug );
        $rs ||= $self->SUPER::delete();
        $rs ||= iMSCP::SystemUser->new( force => TRUE )->delSystemUser( $ug );
        $rs ||= iMSCP::SystemGroup->getInstance()->delSystemGroup( $ug );
        $rs ||= $self->{'eventManager'}->trigger( 'onAfterDeleteImscpUnixUser', $ug );
    } catch {
        error( $_ );
        1;
    };
}

=back

=head1 PRIVATE METHODS

=over 4

=item _loadData( $userId )

 Load data

 Param int $userId user unique identifier
 Return void, die on failure

=cut

sub _loadData
{
    my ( $self, $userId ) = @_;

    my $row = $self->{'_conn'}->run( fixup => sub {
        $_->selectrow_hashref(
            '
                SELECT admin_id, admin_name, admin_pass, admin_sys_name, admin_sys_uid, admin_sys_gname, admin_sys_gid, admin_status
                FROM admin
                WHERE admin_id = ?
            ',
            undef, $userId
        );
    } );
    $row or die( sprintf( 'User (ID %d) has not been found', $userId ));
    %{ $self } = ( %{ $self }, %{ $row } );

}

=item _getData( $action )

 Data provider method for servers and packages

 Param string $action Action
 Return hashref Reference to a hash containing data

=cut

sub _getData
{
    my ( $self, $action ) = @_;

    $self->{'_data'} = do {
        my $user = my $group = $::imscpConfig{'SYSTEM_USER_PREFIX'} . ( $::imscpConfig{'SYSTEM_USER_MIN_UID'}+$self->{'admin_id'} );
        {
            STATUS        => $self->{'admin_status'},
            USER_ID       => $self->{'admin_id'},
            USER_SYS_UID  => $self->{'admin_sys_uid'},
            USER_SYS_GID  => $self->{'admin_sys_gid'},
            USERNAME      => $self->{'admin_name'},
            PASSWORD_HASH => $self->{'admin_pass'},
            USER          => $user,
            GROUP         => $group
        }
    } unless %{ $self->{'_data'} };

    $self->{'_data'}->{'ACTION'} = $action;
    $self->{'_data'};
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
