use strict;
use warnings;

package Dist::Zilla::Plugin::ReadmeAnyFromPod;
# ABSTRACT: Automatically convert POD to a README in any format for Dist::Zilla

use Encode qw( encode );
use IO::Handle;
use Moose::Autobox;
use Moose::Util::TypeConstraints qw(enum);
use Moose;
use MooseX::Has::Sugar;
use Path::Tiny 0.004;
use Scalar::Util 'blessed';

with 'Dist::Zilla::Role::AfterBuild';
with 'Dist::Zilla::Role::AfterRelease';
with 'Dist::Zilla::Role::FileGatherer';
with 'Dist::Zilla::Role::FileMunger';
with 'Dist::Zilla::Role::FilePruner';
with 'Dist::Zilla::Role::MainPodReader';

# TODO: Should these be separate modules?
our $_types = {
    pod => {
        filename => 'README.pod',
        parser => sub {
            return $_[0];
        },
    },
    text => {
        filename => 'README',
        parser => sub {
            my $pod = $_[0];

            require Pod::Simple::Text;
            Pod::Simple::Text->VERSION('3.23');
            my $parser = Pod::Simple::Text->new;
            $parser->output_string( \my $content );
            $parser->parse_characters(1);
            $parser->parse_string_document($pod);
            return $content;
        },
    },
    markdown => {
        filename => 'README.mkdn',
        parser => sub {
            my $pod = $_[0];

            require Pod::Markdown;
            my $parser = Pod::Markdown->new();

            require IO::Scalar;
            my $input_handle = IO::Scalar->new(\$pod);

            $parser->parse_from_filehandle($input_handle);
            my $content = $parser->as_markdown();
            return $content;
        },
    },
    html => {
        filename => 'README.html',
        parser => sub {
            my $pod = $_[0];

            require Pod::Simple::HTML;
            Pod::Simple::HTML->VERSION('3.23');
            my $parser = Pod::Simple::HTML->new;
            $parser->output_string( \my $content );
            $parser->parse_characters(1);
            $parser->parse_string_document($pod);
            return $content;
        }
    }
};

=attr type

The file format for the readme. Supported types are "text",
"markdown", "pod", and "html".  Note that you are not advised to
create a F<.pod> file in the dist itself, as L<ExtUtils::MakeMaker>
will install that, both into C<PERL5LIB> and C<MAN3DIR>.

=cut

has type => (
    ro, lazy,
    isa        => enum([keys %$_types]),
    default    => sub { $_[0]->__from_name()->[0] || 'text' },
);

=attr filename

The file name of the README file to produce. The default depends on
the selected format.

=cut

has filename => (
    ro, lazy,
    isa => 'Str',
    default => sub { $_types->{$_[0]->type}->{filename}; }
);

=attr source_filename

The file from which to extract POD for the content of the README. The
default is the file of the main module of the dist. If there is a pod
file with the same basename as the main module, that is used as the
default instead.

=cut

=attr location

Where to put the generated README file. Choices are:

=over 4

=item build

This puts the README in the directory where the dist is currently
being built, where it will be incorporated into the dist.

=item root

This puts the README in the root directory (the same directory that
contains F<dist.ini>). The README will not be incorporated into the
built dist.

=back

If you want to generate the same README file in both the build
directory and the root directory, simply generate it in the build
directory and use the
L<C<[CopyFilesFromBuild]>|Dist::Zilla::Plugin::CopyFilesFromBuild>
plugin to copy it to the dist root.

=cut

has location => (
    ro, lazy,
    isa => enum([qw(build root)]),
    default => sub { $_[0]->__from_name()->[1] || 'build' },
);

=attr phase

At what phase to generate the README file. Choices are:

=over 4

=item build

(Default) This generates the README at 'after build' time. A new
README will be generated each time you build the dist.

=item release

This generates the README at 'after release' time. Note that this is
too late to get the file into the generated tarball, and is therefore
incompatible with C<location = build>. However, this is ideal if you
are using C<location = root> and only want to update the README upon
each release of your module.

=back

=cut

has phase => (
    ro, lazy,
    isa => enum([qw(build release)]),
    default => 'build',
);

=for Pod::Coverage BUILD mvp_aliases

=cut

sub BUILD {
    my $self = shift;

    $self->log_fatal('You cannot use location=build with phase=release!')
        if $self->location eq 'build' and $self->phase eq 'release';

    $self->log('You are creating a .pod directly in the build - be aware that this will be installed like a .pm file and as a manpage')
        if $self->location eq 'build' and $self->type eq 'pod';
}

sub mvp_aliases {
    {
        source_filename => 'source_file',
    }
}
=method gather_files

We create the file early, so other plugins that need to have the full list of
files are aware of what we will be generating.

=cut

sub gather_files {
    my ($self) = @_;

    my $filename = $self->filename;
    if ( $self->location eq 'build'
         # allow for the file to also exist in the dist
         and not @{$self->zilla->files->grep( sub { $_->name eq $filename })}
       ) {
        require Dist::Zilla::File::InMemory;
        my $file = Dist::Zilla::File::InMemory->new({
            content => 'this will be overwritten',
            name    => $self->filename,
        });

        $self->add_file($file);
    }
    return;
}

=method prune_files

Files with C<location = root> must also be pruned, so that they don't
sneak into the I<next> build by virtue of already existing in the root
dir.  (The alternative is that the user doesn't add them to the build in the
first place, with an option to their C<GatherDir> plugin.)

=cut

sub prune_files {
    my ($self) = @_;

    # leave the file in the dist if another instance of us is adding it there.
    if ($self->location eq 'root'
        and not grep {
            blessed($self) eq blessed($_)
                and $_->location eq 'build'
                and $_->filename eq $self->filename
        } @{$self->zilla->plugins}) {
        for my $file ($self->zilla->files->flatten) {
            next unless $file->name eq $self->filename;
            $self->log_debug([ 'pruning %s', $file->name ]);
            $self->zilla->prune_file($file);
        }
    }
    return;
}

=method munge_files

=cut

sub munge_files {
    my $self = shift;

    if ( $self->location eq 'build' ) {
        my $filename = $self->filename;
        my $file = $self->zilla->files->grep( sub { $_->name eq $filename } )->head;
        if ($file) {
            $self->munge_file($file);
        }
        else {
            $self->log_fatal(
                      "Could not find a $filename file during the build"
                    . ' - did you prune it away with a PruneFiles block?' );
        }
    }
    return;
}

=method munge_file

Edits the content into the requested README file in the dist.

=cut

sub munge_file {
    my ($self, $file) = @_;

    # This check can't be put in the BUILD method because it has to
    # happen *after* the file gathering step.
    # TODO add a test for this
    # This could happen for type=pod if the source file is a pod file.
    $self->log_fatal('Source and destination file are the same')
      if $self->source_file eq $file;

    $self->log_debug([ 'ReadmeAnyFromPod updating contents of %s in dist', $file->name ]);
    $file->content($self->get_readme_content);
    return;
}

=method on_source_file_update

This method is called if the source file is modified after we create
the README file in the dist. It updates the README content to match
the new content of the source file, and emits a warning.

=cut

sub on_source_file_update {
    my $self = shift;
    $self->log('someone tried to munge ' . $self->source_file . ' after we read from it. Making modifications again...');
    $self->munge_files();
}

=method after_build

Create the requested README file at build time, if requested.

=cut

sub after_build {
    my $self = shift;
    $self->_create_readme if $self->phase eq 'build';
}

=method after_release

Create the requested README file at release time, if requested.

=cut

sub after_release {
    my $self = shift;
    $self->_create_readme if $self->phase eq 'release';
}

sub _create_readme {
    my $self = shift;

    if ( $self->location eq 'root' ) {
        my $filename = $self->filename;
        $self->log_debug([ 'ReadmeAnyFromPod updating contents of %s in root', $filename ]);

        my $content = $self->get_readme_content();

        my $file = $self->zilla->root->file($filename);
        if (-e $file) {
            $self->log("overriding $filename in root");
        }
        my $encoding = $self->source_encoding();
        Path::Tiny::path($file)->spew_raw(
            $encoding eq 'raw'
                ? $content
                : encode($encoding, $content)
        );
    }

    return;
}

=method get_readme_content

Get the content of the README in the desired format.

=cut

sub get_readme_content {
    my ($self) = shift;
    my $source_pod = $self->pod_for_source_file();
    my $parser = $_types->{$self->type}->{parser};
    # Save the POD text used to generate the README.
    return $parser->($source_pod);
}

{
    my %cache;
    sub __from_name {
        my ($self) = @_;
        my $name = $self->plugin_name;

        # Use cached values if available
        if ($cache{$name}) {
            return $cache{$name};
        }

        # qr{TYPE1|TYPE2|...}
        my $type_regex = join('|', map {quotemeta} keys %$_types);
        # qr{LOC1|LOC2|...}
        my $location_regex = join('|', map {quotemeta} qw(build root));
        # qr{(?:Readme)? (TYPE1|TYPE2|...) (?:In)? (LOC1|LOC2|...) }x
        my $complete_regex = qr{ (?:Readme)? ($type_regex) (?:(?:In)? ($location_regex))? }ix;
        my ($type, $location) = (lc $name) =~ m{(?:\A|/) \s* $complete_regex \s* \Z}ix;
        $cache{$name} = [$type, $location];
        return $cache{$name};
    }
}

__PACKAGE__->meta->make_immutable;

__END__

=head1 SYNOPSIS

In your F<dist.ini>

    [ReadmeAnyFromPod]
    ; Default is plaintext README in build dir

    ; Using non-default options: POD format with custom filename in
    ; dist root, outside of build. Including this README in version
    ; control makes Github happy.
    [ReadmeAnyFromPod / ReadmePodInRoot]
    type = pod
    filename = README.pod
    location = root

    ; Using plugin name autodetection: Produces README.html in root
    [ ReadmeAnyFromPod / HtmlInRoot ]

=head1 DESCRIPTION

Generates a README for your L<Dist::Zilla> powered dist from its
C<main_module> in any of several formats. The generated README can be
included in the build or created in the root of your dist for e.g.
inclusion into version control.

=head2 PLUGIN NAME AUTODETECTION

If you give the plugin an appropriate name (a string after the slash)
in your dist.ini, it will can parse the C<type> and C<location>
attributes from it. The format is "Readme[TYPE]In[LOCATION]". The
words "Readme" and "In" are optional, and the whole name is
case-insensitive. The SYNOPSIS section above gives one example.

When run with C<location = dist>, this plugin runs in the C<FileMunger> phase
to create the new file. If it runs before another C<FileMunger> plugin does,
that happens to modify the input pod (like, say,
L<C<[PodWeaver]>|Dist::Zilla::Plugin::PodWeaver>), the README file contents
will be recalculated, along with a warning that you should modify your
F<dist.ini> by referencing C<[ReadmeAnyFromPod]> lower down in the file (the
build still works, but is less efficient).

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<rct+perlbug@thompsonclan.org>.

=head1 SEE ALSO

=for :list
* L<Dist::Zilla::Plugin::ReadmeFromPod> - The base for this module
* L<Dist::Zilla::Plugin::ReadmeMarkdownFromPod> - Functionality subsumed by this module
* L<Dist::Zilla::Plugin::CopyReadmeFromBuild> - Functionality partly subsumed by this module
