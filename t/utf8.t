use strict;
use warnings FATAL => 'all';

use utf8;
binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

use Test::More;
use Test::DZil;
use Path::Tiny;

# for now, we need to hack things up a bit, to work around the fact that
# Dist::Zilla::Tester does not yet support reading encoded content from disk
# nor dynamically adding files with unicode content.
# see https://github.com/rjbs/Dist-Zilla/pull/220 and related tickets

# this can all be removed when Dist::Zilla is fixed (but remember to depend on
# the first version containing the fix!)

BEGIN {
my %module = ( path(qw(source lib Foo.pm)) => <<'MODULE' );
package Foo;
use utf8;
=pod

=encoding utf-8

=head1 SYNOPSIS

here's to you, Dagfinn Ilmari Mannsåker, my unicode canary

=cut
1;
MODULE

    # the original is defined in Dist/Zilla/Tester.pm
    my $meta = Moose::Util::find_meta('Dist::Zilla::Tester::_Builder');
    $meta->make_mutable;
    $meta->add_around_method_modifier(from_config =>
        sub {
            my ($orig, $self, $arg, $tester_arg) = @_;

            my $zilla = $self->$orig($arg, $tester_arg);
        
            my ($name, $content) = each %module;
            ::note 'adding ', $name, ' to the dist the hacky way...';
            my $fn = $zilla->tempdir->file($name);

            $fn->dir->mkpath;
            open my $fh, '>', $fn;

            binmode $fh, ':raw:utf8';   # PATCHED from the original
            print $fh $content;
            close $fh;

            return $zilla;
        }
    );
}

my $tzil = Builder->from_config(
    { dist_root => 't/does_not_exist' },
    {
        add_files => {
            'source/dist.ini' => simple_ini(
                'GatherDir',
                # our files are copied into source, so Git::GatherDir doesn't see them
                # and besides, we would like to run these tests at install time too!
                [ ReadmeAnyFromPod => {
                    type => 'pod', filename => 'README.pod', location => 'root',
                } ],
            ),
# TODO: uncomment this when Dist::Zilla is fixed
#            path(qw(source lib Foo.pm)) => <<'MODULE',
# ... include package contents as above
#MODULE
        },
    },
);


$tzil->build;

my $root_dir = $tzil->tempdir->subdir('source');
my $file = path($root_dir, 'README.pod');
ok( -e $file, 'README.pod created in root');

my $content = $file->slurp_utf8;
like($file->slurp_utf8, qr/Dagfinn Ilmari Mannsåker/m, 'file was written with correct encoding');

done_testing;
