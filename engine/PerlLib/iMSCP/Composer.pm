=head1 NAME

 iMSCP::Composer - i-MSCP Composer packages installer

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

package iMSCP::Composer;

use strict;
use warnings;
use iMSCP::Boolean;
use iMSCP::Debug qw/ debug error /;
use iMSCP::Dialog;
use iMSCP::Dir;
use iMSCP::Execute qw/ escapeShell execute executeNoWait /;
use iMSCP::EventManager;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Stepper;
use iMSCP::TemplateParser 'process';
use Try::Tiny;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Composer packages installer for i-MSCP.

=head1 PUBLIC METHODS

=over 4

=item registerPackage( $package [, $packageVersion = 'dev-master' ] )

 Register the given composer package for installation

 Param string $package Package name
 Param string $packageVersion OPTIONAL Package version
 Return int 0

=cut

sub registerPackage
{
    my ( $self, $package, $packageVersion ) = @_;

    $packageVersion ||= 'dev-master';
    push @{ $self->{'packages'} }, "        \"$package\": \"$packageVersion\"";
    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return iMSCP::Composer, die on failure

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'composer_version'} = '1.8.0';
    $self->{'packages'} = [];
    $self->{'packages_dir'} = "$::imscpConfig{'IMSCP_HOMEDIR'}/packages";
    $self->{'su_cmd_pattern'} = "su --login $::imscpConfig{'IMSCP_USER'} --shell /bin/sh -c %s";
    $self->{'php_cmd_prefix'} = "php -d date.timezone=$::imscpConfig{'TIMEZONE'} -d allow_url_fopen=1";

    iMSCP::EventManager->getInstance()->register( 'afterSetupPreInstallPackages', sub {
        my $skipPackagesUpdate = iMSCP::Getopt->skipPackageUpdate;

        if ( iMSCP::Getopt->cleanPackageCache ) {
            $skipPackagesUpdate = FALSE;
            my $rs = $self->_cleanCache();
            return $rs if $rs;
        }

        return 1 unless try {
            iMSCP::Dir->new( dirname => $self->{'packages_dir'} )->make( {
                user  => $::imscpConfig{'IMSCP_USER'},
                group => $::imscpConfig{'IMSCP_GROUP'},
                mode  => 0755
            } );
            TRUE;
        } catch {
            error( $_ );
            FALSE;
        };

        if ( $skipPackagesUpdate ) {
            startDetail;
            my $rs = step( sub {
                return 0 if $self->_checkComposerVersion();
                error( "composer.phar not found or outdated. Please retry without the '-a' option." );
                1;
            }, 'Checking composer.phar version', 2, 1 );
            $rs ||= step( sub {
                return 0 if $self->_checkRequirements( 2, 2 );
                1;
            }, 'Checking composer package requirements', 2, 2 );
            endDetail;
            return $rs;
        }

        startDetail;
        my $rs = step( sub { $self->_getComposer( 1, 1 ); }, 'Installing composer.phar from http://getcomposer.org', 2, 1 );
        $rs ||= step( sub { $self->_installPackages( 2, 2 ); }, 'Installing/Updating composer packages from Github', 2, 2 );
        endDetail;
        $rs;
    } ) if $::execmode eq 'setup';

    $self;
}

=item _getComposer( $steps, $step )

 Get composer.phar

 Param int $steps Total steps
 Param int $step Step number
 Return 0 on success, other on failure

=cut

sub _getComposer
{
    my ( $self, $steps, $step ) = @_;

    return 0 if $self->_checkComposerVersion();

    my $msgHeader = "Installing composer.phar from http://getcomposer.org\n\n";
    my $msgFooter = "\nDepending on your connection, this may take few seconds...";
    my $stderr;

    my $rs = executeNoWait(
        sprintf( $self->{'su_cmd_pattern'}, escapeShell(
            "curl --connect-timeout 20 --silent --show-error http://getcomposer.org/installer | $self->{'php_cmd_prefix'} -- --no-ansi"
                . " --version=$self->{'composer_version'}"
        )),
        ( iMSCP::Getopt->noprompt && iMSCP::Getopt->verbose ? undef : sub { step( undef, $msgHeader . $_[0] . $msgFooter, $steps, $step ); } ),
        sub { $stderr .= $_[0]; }
    );

    error( sprintf( "Couldn't install composer.phar: %s", $stderr || 'Unknown error' )) if $rs;
    $rs;
}

=item _checkComposerVersion( )

 Check composer version

 Return boolean TRUE if composer version match with the expected one, FALSE otherwise

=cut

sub _checkComposerVersion
{
    my ( $self ) = @_;

    return FALSE unless -x "$::imscpConfig{'IMSCP_HOMEDIR'}/composer.phar";

    return FALSE unless execute(
        sprintf( $self->{'su_cmd_pattern'}, escapeShell( "$self->{'php_cmd_prefix'} $::imscpConfig{'IMSCP_HOMEDIR'}/composer.phar --version" )),
        \my $stdout,
        \my $stderr
    ) == 0;
    debug( $stdout ) if $stdout;

    return FALSE unless my ( $version ) = $stdout =~ /^Composer\s+version\s+(\d\.\d\.\d)\s+/;
    return FALSE if version->parse( $version ) != version->parse( $self->{'composer_version'} );
    TRUE;
}

=item _checkRequirements( $steps, $step )

 Check package version requirements

 Param int $steps Total steps
 Return boolean TRUE if all requirements are met, FALSE otherwise

=cut

sub _checkRequirements
{
    my ( $self, $steps, $step ) = @_;

    return 0 unless -d $self->{'packages_dir'};

    for my $package ( @{ $self->{'packages'} } ) {
        ( $package, my $version ) = $package =~ /"(.*)":\s*"(.*)"/;
        my $rs = executeNoWait(
            sprintf( $self->{'su_cmd_pattern'}, escapeShell(
                "$self->{'php_cmd_prefix'} $::imscpConfig{'IMSCP_HOMEDIR'}/composer.phar show --no-ansi --no-interaction"
                    . " --working-dir=$self->{'packages_dir'} $package $version"
            )),
            ( iMSCP::Getopt->noprompt && iMSCP::Getopt->verbose
                ? undef : sub { step( undef, "Checking composer package requirements\n\n Checking package $package ($version)\n\n", $steps, $step ); }
            ),
            sub {}
        );
        if ( $rs ) {
            error( sprintf( "Package %s (%s) not found. Please retry without the '-a' option.", $package, $version ));
            return FALSE;
        }
    }

    TRUE;
}

=item _installPackages( $steps, $step )

 Install or update packages

 Param int $steps Total steps
 Param int $step Step number
 Return 0 on success, other on failure

=cut

sub _installPackages
{
    my ( $self, $steps, $step ) = @_;

    my $rs = $self->_buildComposerFile();
    return $rs if $rs;

    my $msgHeader = "Installing/Updating composer packages from Github\n\n";
    my $msgFooter = "\nDepending on your connection, this may take few seconds...";

    # Note: Any progress/status info goes to stderr (See https://github.com/composer/composer/issues/3795)
    $rs = executeNoWait(
        sprintf( $self->{'su_cmd_pattern'}, escapeShell(
            "$self->{'php_cmd_prefix'} $::imscpConfig{'IMSCP_HOMEDIR'}/composer.phar update --no-ansi --no-interaction"
                . " --working-dir=$self->{'packages_dir'}"
        )),
        sub {},
        ( iMSCP::Getopt->noprompt && iMSCP::Getopt->verbose ? undef : sub { step( undef, $msgHeader . $_[0] . $msgFooter, $steps, $step ); } )
    );

    error( "Couldn't install/update i-MSCP packages from GitHub" ) if $rs;
    $rs;
}

=item _buildComposerFile( )

 Build composer.json file

 Return 0 on success, other on failure

=cut

sub _buildComposerFile
{
    my ( $self ) = @_;

    my $tpl = <<'TPL';
{
    "name": "imscp/packages",
    "description": "i-MSCP composer packages",
    "licence": "GPL-2.0+",
    "require": {
{PACKAGES}
    },
    "config": {
        "preferred-install": "dist",
        "process-timeout": 2000,
        "discard-changes": true
    },
    "minimum-stability": "dev"
}
TPL

    my $file = iMSCP::File->new( filename => "$self->{'packages_dir'}/composer.json" );
    $file->set( process( { PACKAGES => join ",\n", @{ $self->{'packages'} } }, $tpl ));
    $file->save();
}

=item _cleanCache( )

 Clear composer package cache

 Return 0 on success, 1 on failure

=cut

sub _cleanCache
{
    my ( $self ) = @_;

    try {
        for my $dir ( "$::imscpConfig{'IMSCP_HOMEDIR'}/.cache", "$::imscpConfig{'IMSCP_HOMEDIR'}/.composer", $self->{'packages_dir'} ) {
            iMSCP::Dir->new( dirname => $dir )->remove();
        }

        0;
    } catch {
        error( $@ );
        1;
    };
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
