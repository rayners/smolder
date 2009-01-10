package Smolder::Platform;
use strict;
use warnings;

use File::Spec::Functions qw(catdir catfile canonpath);
use Cwd qw(cwd);
use Config;
use File::Basename;
use Devel::CheckLib qw(assert_lib);

my $DEBUG = 0;

# find out which subclasses we support
my $PLATFORM_DIR = catdir( $ENV{SMOLDER_ROOT}, 'platform' );
opendir( DIR, $PLATFORM_DIR ) or die $!;
our @PLATFORMS = grep {
    $_ !~ /^\.\.?$/        # not the parent or a hidden file
      and $_ !~ /\.svn/    # ignore SVN cruft
} sort readdir DIR;

=head1 NAME

Smolder::Platform - base class for platform build modules

=head1 SYNOPSIS

  package Redhat9::Platform;
  use base 'Smolder::Platform';

=head1 DESCRIPTION

This module serves as a base class for the platform build modules
which build help Smolder binary distributions.  See
F<docs/build_tech_spec.pod> for details about how the build system
works.

=head1 METHODS

This module is meant to be used as a base class, so the interface
consists of methods which may be overridden.  All these methods have a
reasonable default behavior.

All methods are called as class methods.  Platform modules are free to
use package variables to hold information between calls.

=head2 load

This method will load the correct subclass. It can be specified, or
it will be divined.

    # if you know what you need
    my $platform = Smolder::Platform->load('FedoraCore3');

    # or if don't
    my $platform = Smolder::Platform->load();

=cut

sub load {
    my ( $class, $subclass, $search ) = @_;

    # add in $SMOLDER_ROOT/platform for platform build modules
    my $plib = catdir( $ENV{SMOLDER_ROOT}, "platform" );
    $ENV{PERL5LIB} = "$ENV{PERL5LIB}:${plib}";
    unshift @INC, $plib;

    # try it if we got it
    if ($subclass) {
        $subclass = $subclass . '::Platform';
        eval "use $subclass";
        die "Unable to load platform module '$subclass': $@\n" if $@;

    } else {
        # check a previous build
        my %build_params = $class->build_params();

        # if we were previously built for a platform
        if ( !$search && $build_params{Platform} ) {
            $subclass = $build_params{Platform} . '::Platform';
            eval "use $subclass";
            die "Unable to load platform module '$subclass': $@\n" if $@;
        } else {
            # look for a platform that wants to handle this
            foreach my $plat (@PLATFORMS) {
                print "Trying $plat\n" if $search;
                my $pkg = $plat . '::Platform';
                eval "use $pkg";
                die "Unable to load platform modules '$pkg': $@\n" if $@;

                if ( $pkg->guess_platform ) {
                    $subclass = $pkg;
                    last;
                }
            }
        }
    }
    return $subclass;
}

=head2 verify_dependencies

Makes sure all required dependencies are in place before starting the
build, and before beginning installation.  The C<mode> parameter will
be either "build" or "install" depending on when the method is called.

This method should either succeed or die() with a message for the
user.

By default, shared object (.so) files are searched for in $Config{libpth}.
header files (.h) are search for in $Config{usrinc}, /include and /usr/local/include

The default implementation runs the following default checks (which
are all overrideable):

=over

=item *

If installing, verify that we have a Perl with the same version that
the Smolder binary was built against.

=item *

Make sure we have the correct databases installed. Right now this
means SQLite and MySQL. These can be skipped by providing the
C<no_mysql> and C<no_sqlite> params.

=item *

Make sure we have libgd installed.

=back

    verify_dependencies(
        mode     => 'install',
        no_mysql => 1,
    )

=cut

sub verify_dependencies {

    my ( $pkg, %arg ) = @_;
    my $mode = $arg{mode};
    my @PATH = split( ':', ( $ENV{PATH} || "" ) );

    # check perl
    if ( $mode eq 'install' ) {
        $pkg->check_perl();
    }

    # check the database
    $pkg->check_databases( mode => $mode, no_mysql => $arg{no_mysql}, no_sqlite => $arg{no_sqlite} );

    # look for necessary libs
    $pkg->check_libperl( mode => $mode );
    $pkg->check_libgd( mode => $mode );
    $pkg->check_libssl( mode => $mode );

    # make sure we don't have a broken ExtUtils::Install (!1.42 or 1.43)
    require ExtUtils::Install;
    if($ExtUtils::Install::VERSION == 1.42 or $ExtUtils::Install::VERSION == 1.43) {
        die "You have a broken version of ExtUtils::Install! Please upgrade to 1.44 or greater.\n";
    }
}

=head2 check_databases 

This class method will cycle through all available database platform modules
(subclasses of L<Smolder::DBPlatform>), load them and run their C<verify_dependencies()>
method.

=cut

sub check_databases {
    my ( $self, %args ) = @_;
    my $mode = $args{mode};
    my $no_mysql = $args{no_mysql};
    my $no_sqlite = $args{no_sqlite};

    my @dbs;
    # our list of available DBPlatforms comes from build.db when installing
    if( $mode eq 'install' ) {
        my %build_params = $self->build_params();
        @dbs = @{$build_params{DBPlatforms}}
    } else {
        # else get the list from the available modules
        my $db_platform_dir = catdir( $ENV{SMOLDER_ROOT}, 'lib', 'Smolder', 'DBPlatform' );
        opendir( my $DIR, $db_platform_dir ) or die $!;
        @dbs = grep {
            $_ !~ /^\.\.?$/        # not the parent or a hidden file
              and $_ !~ /\.svn/    # ignore SVN cruft
              and $_ !~ /~$/       # ignore editor droppings
              and $_ !~ /\.swp$/
        } sort readdir $DIR;
    }

    # now load each db platform and verify it
    require Smolder::DBPlatform;
    foreach my $db (@dbs) {
        my $basename = basename( $db, '.pm' );
        next if $no_mysql && lc $basename eq 'mysql';
        next if $no_sqlite && lc $basename eq 'sqlite';
        my $db_platform = Smolder::DBPlatform->load($basename);
        $db_platform->verify_dependencies( mode => $mode );
    }
}

=head2 check_perl

Perl is the right version and compiled for the right architecture
(skipped in build mode).

=cut

sub check_perl {

    my $pkg = shift;

    # check that Perl is right for this build
    my %params = $pkg->build_params();

    my $perl = join( '.', ( map { ord($_) } split( "", $^V, 3 ) ) );
    if ( $perl ne $params{Perl} ) {
        die <<END;

This distribution of Smolder is compiled for Perl version
'$params{Perl}', but you have '$perl' installed.  You must either
install the expected version of Perl, or download a different release
of Smolder.  Please see the installation instructions in INSTALL for
more details.

END
    }

    if ( $Config{archname} ne $params{Arch} ) {
        die <<END;

This distribution of Smolder is compiled for the '$params{Arch}'
architecture, but your copy of Perl is compiled for
'$Config{archname}'.  You must download a different Smolder
distribution, or rebuild your Perl installation.  Please see the
installation instructions in INSTALL for more details.

END
    }
}

=head2 check_libgd

Checks for the existance of the libgd shared object and header files.

    check_libgd(mode  => 'install');

=cut

sub check_libgd {
    my ( $pkg, %args ) = @_;
    $pkg->check_libs(
        %args,
        h      => 'gd.h',
        name   => 'libgd',
        so     => 'libgd',
        module => 'GD',
    );
}

=head2 check_libssl

Checks for the existance of the SSL shared object and header files.

    check_libssl(mode  => 'install');

=cut

sub check_libssl {
    my ( $pkg, %args ) = @_;
    $pkg->check_libs(
        %args,
        name   => 'libssl',
        so     => 'libssl',
        module => 'Net::SSLeay',
    );
}

=head2 check_libperl

Checks for the existance of the libperl shared object and header files.

    check_libperl(mode  => 'install');

=cut

sub check_libperl {
    my ($pkg, %args) = @_;
    $pkg->check_libs(
        %args,
        name     => 'libperl',
        so       => 'libperl',
        includes => [catdir($Config{archlib}, 'CORE')],
        libs     => [catdir($Config{archlib}, 'CORE')],
    );
}

=head2 check_libs

Method to actually search for libraries. This method is used to check
for the necessary F<.h> and F<.so> files. It takes the following named args:

=over

=item mode

Either C<build> or C<install>. Required.

=item h

The name of the header (.h) file to look for. These files will not
be searched for if C<mode> is 'install'. Optional.

=item so

The name of the shared object (.so) file to look for. Optional.
This is minus the F<.so> extension since it's different on different
platforms.

=item name

The name of the library, used for error messages. Required.

=item module

The name of the Perl module that needs the library,
used for error messages. Optional

=item includes

An array ref of directories to search for the .h files.
By default it will look in your directories in your Perl's 
C<$Config{usrinc}>, F</include> and F</usr/local/include>.
Optional.

=item libs

An array ref of directories to search for the .so files. 
By default it will look in your directories in your Perl's 
C<$Config{libpth}>.
Optional.

=back

    $pkg->check_libs(
        h      => 'gd.h',
        so     => 'libgd',
        name   => 'libgd',
        module => 'GD',
    );

=cut

sub check_libs {
    my ( $pkg, %args ) = @_;
    my $mode = $args{mode};
    my $name = $args{name};
    my $so   = $args{so};
    my $h    = $args{h};
    my $mod  = $args{module};

    if ($so) {
        my $lib = $so;
        $lib =~ s/^lib//;
        my @libs;
        push(@libs, @{$args{libs}}) if $args{libs}; # extra dirs supplied when called
        eval { assert_lib(lib => $lib, libpath => \@libs, debug => $DEBUG) };
        die "\n\n$name is missing from your system or Smolder could not find it."
            . "\nThis library is required by Smolder.\n\n" if $@;
    }

    if ($h && $mode eq 'build') {
        my @incs;
        push(@incs, @{$args{includes}}) if $args{includes}; # extra dirs supplied when called
        my $msg = "The header file for $name, '$h', is missing from your system "
         . "or Smolder can't find it.";
        $msg .= "\nThis file is needed to compile the $mod module which uses $name." if ($mod && $name);
        eval { assert_lib(header => $h, incpath => \@incs, debug => $DEBUG) };
        die "$msg\n" if $@;
    }
}

=head2 find_bin

If $ENV{PATH} exists, searches $ENV{PATH} for $bin_name, returning the
full path to the desired executable.

If $ENV{PATH} does not contain /sbin or /usr/sbin, it will search those as well.

will die() with error if it cannot find the desired executable.

    $bin = find_bin(bin => $bin_name);

=cut

sub find_bin {

    my ( $pkg, %args ) = @_;

    my $bin = $args{bin};
    my $dir;

    my %additional_paths = (
        catdir( '/', 'sbin' ) => 1,
        catdir( '/', 'usr', 'sbin' ) => 1
    );

    my @PATH = split( ':', ( $ENV{PATH} || "" ) );

    foreach $dir (@PATH) {
        delete( $additional_paths{$dir} ) if ( $additional_paths{$dir} );
    }

    push @PATH, keys(%additional_paths);

    foreach $dir (@PATH) {

        my $exec = catfile( $dir, $bin );

        return $exec if ( -e $exec );
    }

    my $path = join ':', @PATH;

    die "Cannot find required utility '$bin' in PATH=$path\n\n";

}

=head2 check_ip

Called by the installation system to check whether an IP address is
correct for the machine.  The default implementation runs
/sbin/ifconfig and tries to parse the resulting text for IP addresses.
Should return 1 if the IP address is ok, 0 otherwise.

    check_ip(ip => $ip);

=cut

sub check_ip {
    my ( $pkg, %arg ) = @_;
    my $IPAddress = $arg{ip};

    my $ifconfig = `/sbin/ifconfig`;
    my @ip_addrs = ();
    foreach my $if_line ( split( /\n/, $ifconfig ) ) {
        next unless ( $if_line =~ /inet\ addr\:(\d+\.\d+\.\d+\.\d+)/ );
        my $ip = $1;
        push( @ip_addrs, $ip );
    }
    unless ( grep { $_ eq $IPAddress } @ip_addrs ) {
        return 0;
    }
    return 1;
}

=head2 create_group

Called to create a Smolder Group, as specified by the command-line
argument to bin/smolder_install (--Group).  Takes the %options hash
built by smolder_install as the one argument.

The default version of this sub works for GNU/Linux.  Other platforms
(e.g. BSD-like) will need to override this method to work with their
platforms' requirements for user creation.

The sub will check to see if --Group exists, and create it if it
does not.  It will return the group ID (gid) in either case.

This sub will die with an error if it cannot create --Group.

    $gid = create_group(options => \%options);

=cut

sub create_group {
    my ( $pkg, %args ) = @_;

    my %options = %{ $args{options} };

    my $groupadd_bin = $pkg->find_bin( bin => 'groupadd' );

    my $group = $options{Group};

    print "Creating UNIX group ('$group')\n";
    my ( $gname, $gpasswd, $gid, $gmembers ) = getgrnam($group);

    unless ( defined($gid) ) {
        my $groupadd = $groupadd_bin;
        $groupadd .= " $group";
        system($groupadd) && die("Can't add group: $!");

        ( $gname, $gpasswd, $gid, $gmembers ) = getgrnam($group);
        print "  Group created (gid $gid).\n";

    } else {
        print "  Group already exists (gid $gid).\n";
    }

    return $gid;
}

=head2 create_user

Called to create a Smolder User, as specified by the command-line
argument to bin/smolder_install (--User).  Takes the %options hash
built by smolder_install as the one argument.

The default version of this sub works for GNU/Linux.  Other platforms
(e.g. BSD-like) will need to override this method to work with their
platforms' requirements for user creation.

The sub will check to see if --User exists, and create it if it
does not.  If the user is created, the default group will be
--Group.  If the user already exists, it will be made a member of
the --Group group.

The sub will return the user ID (uid) if successful.

This sub will die with an error if it cannot create --User.

    $uid = create_user(
        group_id => $gid, 
        options => \%options
    )

=cut

sub create_user {

    my ( $pkg, %args ) = @_;

    my %options = %{ $args{options} };

    my $useradd_bin = $pkg->find_bin( bin => 'useradd' );

    my $user        = $options{User};
    my $group       = $options{Group};
    my $InstallPath = $options{InstallPath};

    # Get group info.
    my ( $gname, $gpasswd, $gid, $gmembers ) = getgrnam($group);

    # Create user, if necessary
    print "Creating UNIX user ('$user')\n";
    my ( $uname, $upasswd, $uid, $ugid, $uquota, $ucomment, $ugcos, $udir, $ushell, $uexpire ) =
      getpwnam($user);

    unless ( defined($uid) ) {
        my $useradd = $useradd_bin;

        $useradd .= " -d $InstallPath -M $user -g $gid";
        system($useradd) && die("Can't add user: $!");

        # Update user data
        ( $uname, $upasswd, $uid, $ugid, $uquota, $ucomment, $ugcos, $udir, $ushell, $uexpire ) =
          getpwnam($user);
        print "  User created (uid $uid).\n";
    } else {
        print "  User already exists (uid $uid).\n";
    }

    # Sanity check - make sure the user is a member of the group.
    ( $gname, $gpasswd, $gid, $gmembers ) = getgrnam($group);

    my @group_members = ( split( /\s+/, $gmembers ) );
    my $user_is_group_member = ( grep { $_ eq $user } @group_members );

    unless ( ( $ugid eq $gid ) or $user_is_group_member ) {
        $pkg->smolder_usermod( options => \%options );
    }

    return $uid;

}

=head2 usermod

Called when --User is not a member of --Group.  This sub
adds --User to --Group.

The default version of this sub works for GNU/Linux.  Other platforms
(e.g. BSD-like) will need to override this method to work with their
platforms' requirements for user creation.

This sub will die with an error if it cannot make --User a member
of --Group.

    usermod(options => \%options)

=cut

sub smolder_usermod {
    my ( $pkg, %args ) = @_;

    my %options = %{ $args{options} };

    my $user  = $options{User};
    my $group = $options{Group};

    print "  Adding user $user to group $group.\n";

    my $usermod = $pkg->find_bin( bin => 'usermod' );

    $usermod .= " -G $group $user";

    system($usermod) && die("Can't add user $user to group $group: $!");
    print "  User added to group.\n";
}

=head2 build_perl_module

Called to build a specific Perl module distribution called C<$name> in
the current directory.  The result of calling this method should be
one or more compiled Perl modules in Smolder's C<lib/> directory.

The default implementation includes code to answer questions asked by
some of the modules (using Expect) and special build procedures for
others.

The optional 'dest_dir' parameter specifies the location to put the
results of the build.  The default is SMOLDER_ROOT/lib.

    build_perl_module(name => $name)

=cut

sub build_perl_module {
    my ( $pkg, %arg ) = @_;
    my $name     = $arg{name};
    my $dest_dir = $arg{dest_dir} || catdir( $ENV{SMOLDER_ROOT}, 'lib' );

    # load expect unless we're building it
    my $use_expect = ( $name =~ /IO-Tty/ or $name =~ /Expect/ ) ? 0 : 1;
    _load_expect() if $use_expect;

    my $trash_dir = catdir( cwd, '..', 'trash' );

    print "\n\n************************************************\n\n", " Building $name",
      "\n\n************************************************\n\n";

    my $EXTRA_ARGS = '';

    # Net::SSLeay needs this to find openssl
    $EXTRA_ARGS = '/usr -- ' if $name =~ /Net_SSLeay/;

    # Net::FTPServer needs this to not try to install /etc/ftp.conf
    local $ENV{NOCONF} = 1 if $name =~ /Net-FTPServer/;

    # libapreq needs to know where to find our apache
    local $ENV{APXS} = catfile($ENV{SMOLDER_ROOT}, 'apache', 'bin', 'apxs')
        if $name =~ /libapreq/;

    # point Apache::Test to our local httpd
    $EXTRA_ARGS = ' -httpd ' . catfile($ENV{SMOLDER_ROOT}, 'apache', 'bin', 'httpd')
        if $name =~ /Apache-Test/;

    # Module::Build or MakeMaker?
    my ( $cmd, $make_cmd );
    if ( -e 'Build.PL' ) {
        $cmd =
            "PERL_MM_USE_DEFAULT=1 $^X Build.PL $EXTRA_ARGS "
          . " --install_path lib=$dest_dir"
          . " --install_path libdoc=$trash_dir"
          . " --install_path script=$trash_dir"
          . " --install_path bin=$trash_dir"
          . " --install_path bindoc=$trash_dir"
          . " --install_path arch=$dest_dir/$Config{archname}";

        $make_cmd = './Build';
    } else {
        $cmd =
            "PERL_MM_USE_DEFAULT=1 $^X Makefile.PL $EXTRA_ARGS "
          . "LIB=$dest_dir "
          . "PREFIX=$trash_dir "
          . "INSTALLMAN3DIR=' ' "
          . "INSTALLMAN1DIR=' '";
        $make_cmd = 'make';
    }

    # We only want the libs, not the executables or man pages
    if ($use_expect) {
        print "Running $cmd...\n";
        $pkg->expect_questions(
            cmd       => $cmd,
            questions => $pkg->perl_module_questions(),
        );

        print "Running $make_cmd...\n";
        $pkg->expect_questions(
            cmd       => $make_cmd,
            questions => $pkg->perl_module_questions(),
        );

    } else {

        # do it without Expect for IO-Tty and Expect installation.
        # Fortunately they don't ask any questions.
        print "Running $cmd...\n";
        system($cmd) == 0
          or die "$cmd failed: $?";
    }

    system("$make_cmd install") == 0 or die "$make_cmd install failed: $?";
}

=head2 first_perl_modules

Returns a list of strings that are used to match against the Perl modules
in the F<src/> directory to shuffle them to the front of the build list. 
By default it's just the C<Module-Build>, C<Expect> and C<IO-Tty> modules.

=cut

sub first_perl_modules {
    return qw(Module-Build Expect IO-Tty);
}

=head2 last_perl_modules

Returns a list of strings that are used to match against the Perl modules
in the F<src/> directory to shuffle them to the back of the build list. 
By default it's just the C<DBD-mysql> and C<DBD-SQLite> modules.

=cut

sub last_perl_modules {
    return qw(DBD-mysql DBD-SQLite);
}

=head2 skip_perl_modules

Returns a list of strings that are used to match against the Perl modules
in the F<src/> directory to remove them from the build list. Certain
modules may only be needed on certain platforms.
By default it's just the C<BSD> modules.

=cut

sub skip_perl_modules {
    return qw(BSD);
}

=head2 dev_perl_modules

Returns a list of strings that are used to match against the Perl modules
in the F<src/> directory to remove them from the build list if we aren't.
building a setup for a developer.

=cut

sub dev_perl_modules {
    return qw(
        Apache-Reload
        Module-Depends
        Pod-Parser
        Pod-Xhtml
    );
}

=head2 apache_modperl_questions

This method returns a hashref where the keys are the questions (or the beginnings of
those questions) that Apache/mod_perl may prompt the user to answer during the install.
The values are the answers to those questions.

=cut

sub apache_modperl_questions {
    return {
        "Configure mod_perl with" => 'y',
        "Shall I build httpd"     => 'n',
    };
}

=head2 perl_module_questions

This method returns a hashref where the keys are the questions (or the beginnings of
those questions) that Perl modules may prompt the user to answer during the install.
The values are the answers to those questions.
Additions should be made as new CPAN modules are added.

=cut

sub perl_module_questions {
    return {
        "ParserDetails.ini?"                            => 'n',
        "remove gif support?"                           => 'n',
        "mech-dump utility?"                            => 'n',
        "configuration (y|n) ?"                         => 'n',
        "unicode entities?"                             => 'n',
        "Do you want to skip these tests?"              => 'y',
        "('!' to skip)"                                 => '!',
        "Mail::Sender? (y/N)"                           => 'n',
        "requires access to an existing test database." => 'n',
        "Do you want to build the XS Stash module?"     => 'y',
        "Do you want to use the XS Stash"               => 'y',
        "Do you want to enable the latex filter?"       => 'n',
        "Do you want to install these components?"      => 'n',
        "Do you wish to install the 'runtests' utility" => 'n',
        # all Smolder graphs are PNGs, and this is a private copy
        "Build PNG support? [y]"                        => 'y',
        "Build JPEG support? [y]"                       => 'n',
        "Build FreeType support? [y]"                   => 'n',
        "Build support for animated GIFs? [y]"          => 'n',
        "Build XPM support? [y]"                        => 'n',
        "Where is libgd installed? [/usr/lib]"          => '/usr/lib',
        "Add Object::Deadly"                            => 'n',
        "prerequisites for testing"                     => 'no',
    };
}

=head2 expect_questions

Given a command and a hashref of questions this method will run the command
and answer the questions as they appear (it is has a match).

    expect_questions(
        cmd         => 'Makefile.PL',
        questions   => $pkg->perl_module_questions(),
    );

=cut

sub expect_questions {
    my ( $pkg, %options ) = @_;
    my $command   = Expect->spawn( $options{cmd} );
    my @responses = values %{ $options{questions} };
    my @questions = keys %{ $options{questions} };

    while ( my $match = $command->expect( undef, @questions ) ) {
        $command->send( $responses[ $match - 1 ] . "\n" );
    }
    $command->soft_close();
    if ( $command->exitstatus() != 0 ) {
        die "$options{cmd} failed: $?";
    }
}

=head2 build_apache_modperl

Called to build Apache and mod_perl in their respective locations.
Uses C<apache_build_parameters()> and C<modperl_build_parameters()>
which may be easier to override.  The result should be a working
Apache installation in C<apache/>.

    build_apache_modperl(
        apache_dir       => $dir, 
        modperl_dir      => $dir, 
        debug            => 0,
    )

=cut

sub build_apache_modperl {
    my ( $pkg, %arg ) = @_;
    my ( $apache_dir, $mod_perl_dir, $debug ) =
      @arg{qw(apache_dir mod_perl_dir debug)};
    _load_expect();

    print "\n\n************************************************\n\n",
      "  Building Apache/mod_perl",
      "\n\n************************************************\n\n";

    # gather params
    my $apache_params   = $pkg->apache_build_parameters(%arg);
    my $mod_perl_params = $pkg->mod_perl_build_parameters(%arg);
    my $old_dir         = cwd;

    print "\n\n************************************************\n\n", "  Building mod_perl",
      "\n\n************************************************\n\n";

    # build mod_perl
    chdir($mod_perl_dir) or die "Unable to chdir($mod_perl_dir): $!";
    my $cmd = "$^X Makefile.PL $mod_perl_params";
    print "Calling '$cmd'...\n";

    my $command = $pkg->expect_questions(
        cmd       => $cmd,
        questions => $pkg->apache_modperl_questions(),
    );

    system("make PERL=$^X") == 0
      or die "mod_perl make failed: $?";
    system("make install PERL=$^X") == 0
      or die "mod_perl make install failed: $?";

    print "\n\n************************************************\n\n", "  Building Apache",
      "\n\n************************************************\n\n";

    # build Apache
    chdir($old_dir)    or die $!;
    chdir($apache_dir) or die "Unable to chdir($apache_dir): $!";
    print "Calling './configure $apache_params'.\n";
    system("./configure $apache_params") == 0
      or die "Apache configure failed: $?";
    system("make") == 0
      or die "Apache make failed: $?";
    system("make install") == 0
      or die "Apache make install failed: $?";

    # clean up unneeded apache directories
    my $root = $ENV{SMOLDER_ROOT};
    system("rm -rf $root/apache/man $root/apache/htdocs/*");
}

=head2 apache_build_parameters

Returns a string containing the parameters passed to Apache's
C<configure> script by C<build_apache_modperl()>.

    apache_build_parameters(
        apache_dir  => $dir, 
        modperl_dir => $dir
    )

=cut

sub apache_build_parameters {
    my ($pkg, %arg) = @_;
    my $debug = $arg{debug};
    my $root  = $ENV{SMOLDER_ROOT};
    my $params = "--prefix=${root}/apache "
      . "--activate-module=src/modules/perl/libperl.a "
      . "--disable-shared=perl "
      . "--enable-module=rewrite      --enable-shared=rewrite "
      . "--enable-module=proxy        --enable-shared=proxy "
      . "--enable-module=mime_magic   --enable-shared=mime_magic "
      . "--enable-module=unique_id    --enable-shared=unique_id "
      . "--enable-module=expires "
      . "--enable-module=headers "
      . "--enable-module=so";
    if( $debug ) {
        $params .= ' --without-execstrip';
    }
    return $params;
}

=head2 mod_perl_build_parameters

Returns a string containing the parameters passed to mod_perl's
C<Makefile.PL> script by L<build_apache_modperl>.

    mod_perl_build_parameters(
        apache_dir  => $dir, 
        modperl_dir => $dir
    );

=cut

sub mod_perl_build_parameters {
    my ( $pkg, %arg ) = @_;
    my $root  = $ENV{SMOLDER_ROOT};
    my $trash = catdir( cwd, '..', 'trash' );
    my $debug = $arg{debug};

    my $params = "LIB=$root/lib "
      . "PREFIX=$trash "
      . "APACHE_SRC=$arg{apache_dir}/src "
      . "USE_APACI=1 "
      . "APACI_ARGS='--without-execstrip' EVERYTHING=1";
    $params .= ' PERL_DEBUG=1' if( $debug );
    return $params;
}

=head2 finish_installation

Anything that needs to be done at the end of installation can be done
here.  The default implementation does nothing.  The options hash
contains all the options passed to C<smolder_install> (ex: InstallPath).

    finish_installation(options => \%options)>

=cut

sub finish_installation { }

=head2 finish_upgrade

Anything that needs to be done at the end of an upgrade can be done
here. The default implementation does nothing.

=cut

sub finish_upgrade { }

=head2 post_install_message

Called by bin/smolder_install, returns install information once everything
is complete.

    post_install_message(options => \%options)

=cut

sub post_install_message {

    my ( $pkg, %args ) = @_;

    my %options = %{ $args{options} };

    my $report = qq(

#####                                                         #####
###                                                             ###
                   Smolder INSTALLATION COMPLETE               
###                                                             ###
#####                                                         #####


   Installed at   : $options{InstallPath}
   Control script : $options{InstallPath}/bin/smolder_ctl
   Config file    : $options{InstallPath}/conf/smolder.conf
   Admin Password : 'qa_rocks'


   Running on $options{IPAddress} - http://$options{HostName}:$options{Port}/

);
    print $report;
}

=head2 post_upgrade_message

Called by bin/smolder_upgrade, returns upgrade information once everything
is complete.

    post_upgrade_message(options => \%options)

=cut

sub post_upgrade_message {

    my ( $pkg, %args ) = @_;

    my %options = %{ $args{options} };

    my $report = qq(


#####                                                         #####
###                                                             ###
                  Smolder UPGRADE COMPLETE                       
###                                                             ###
#####                                                         #####


   Installed at:      $options{InstallPath}
   Control script:    $options{InstallPath}/bin/smolder_ctl
   Smolder conf file: $options{InstallPath}/conf/smolder.conf
 

);
    if( $pkg->has_sudo ) {
        $report .= "Running on $options{IPAddress} -- http://$options{HostName}:$options{Port}/\n\n";
    } else {
        $report .= "Start smolder with bin/smolder_ctl\n\n";
    }
    print $report;
}

=head2 guess_platform

Called to guess whether this module should handle building on this
platform.  This is used by C<smolder_build> when the user doesn't
specify a platform.  This method should return true if the module
wants to handle the platform.

The default implementation returns false all the time.  When
implementing this module, err on the side of caution since the user
can always specify their platform explicitely.

=cut

sub guess_platform {
    return 0;
}

=head2 build_params

Reads the F<data/build.db> file produced by C<smolder_build> and returns
a hash of the values available (Platform, Perl, Arch).

=cut

sub build_params {
    my $db_file = catfile( $ENV{SMOLDER_ROOT}, 'data', 'build.db' );
    return () unless -e $db_file;

    # it would be nice to use Config::ApacheFormat here, but
    # unfortunately it's not possible to guarantee that it will load
    # because it uses Scalar::Util which is an XS module.  If the
    # caller isn't running the right architecture then it will fail to
    # load.  So, fall back to parsing by hand...
    open( DB, $db_file ) or die "Unable to open '$db_file': $!\n";
    my ( $platform, $perl, $arch, @db_plats, $dev );
    while (<DB>) {
        chomp;
        next if /^\s*#/;
        if (/^\s*platform\s+["']?([^'"]+)["']?/i) {
            $platform = $1;
        } elsif (/^\s*perl\s+["']?([^'"]+)/i) {
            $perl = $1;
        } elsif (/^\s*arch\s+["']?([^'"]+)/i) {
            $arch = $1;
        } elsif (/^\s*dbplatforms\s+["']?([^'"]+)/i) {
            @db_plats = split( /,\s*/, $1 );
        } elsif (/^\s*dev\s+["']?([^'"]+)/i) {
            $dev = $1;
        }
    }
    close DB;

    return (
        Platform    => $platform,
        Perl        => $perl,
        Arch        => $arch,
        DBPlatforms => \@db_plats,
        Dev         => $dev,
    );
}

=head2 has_sudo

This method let's us know if this plaform has the C<sudo> command.

=cut

sub has_sudo { 1 };

sub _load_expect {

    # load Expect - don't load at compile time because this module is
    # used during install when Expect isn't needed
    eval "use Expect;";
    die <<END if $@;

Unable to load the Expect Perl module.  You must install Expect before
running smolder_build.  The source packages you need are included with
Project:

   src/IO-Tty-1.02.tar.gz
   src/Expect-1.15.tar.gz

END
}

1;
