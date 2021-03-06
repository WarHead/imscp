=head1 NAME

 Servers::sqld - i-MSCP sqld server implementation

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

package Servers::sqld;

use strict;
use warnings;
use iMSCP::Debug 'fatal';
use Try::Tiny;

# sqld server instance
my $instance;

=head1 DESCRIPTION

 i-MSCP sqld server implementation.

=head1 PUBLIC METHODS

=over 4

=item factory( )

 Create and return sqld server instance

 Return sqld server instance

=cut

sub factory
{
    return $instance if defined $instance;

    try {
        my $package = $::imscpConfig{'SQL_PACKAGE'} || 'Servers::noserver';
        eval "require $package" or die;
        $instance = $package->getInstance();
    } catch {
        fatal( $_ );
    };
}

=item can( $method )

 Checks if the sqld server package provides the given method

 Param string $method Method name
 Return subref|undef

=cut

sub can
{
    my ( undef, $method ) = @_;

    try {
        my $package = $::imscpConfig{'SQL_PACKAGE'} || 'Servers::noserver';
        eval "require $package" or die;
        $package->can( $method );
    } catch {
        fatal( $_ );
    };
}

=item getPriority( )

 Get server priority

 Return int Server priority

=cut

sub getPriority
{
    80;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
