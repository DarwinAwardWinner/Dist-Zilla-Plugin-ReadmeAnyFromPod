use strict;
use warnings;

package Dist::Zilla::Plugin::ReadmeAnyFromPod;
# ABSTRACT: Automatically convert POD to a README in any format for Dist::Zilla

use IO::Handle;
use List::Util qw( reduce );
use Moose::Autobox;
use Moose::Util::TypeConstraints qw(enum);
use Moose;
use MooseX::Has::Sugar;
use PPI::Document;
use PPI::Token::Pod;

# This cannot be the FileGatherer role, because it needs to be called
# after file munging to get the fully-munged POD.
with 'Dist::Zilla::Role::InstallTool';
with 'Dist::Zilla::Role::FilePruner';

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
            my $parser = Pod::Simple::HTML->new;
            $parser->output_string( \my $content );
            $parser->parse_characters(1);
            $parser->parse_string_document($pod);
            return $content;
        }
    }
};

=attr type

The file format for the readme. Supported types are "text", "markdown", "pod", and "html".

=cut

has type => (
    ro, lazy,
    isa        => enum([keys %$_types]),
    default    => sub { $_[0]->__from_name()->[0] || 'text' },
);

=attr filename

The file name of the README file to produce. The default depends on the selected format.

=cut

has filename => (
    ro, lazy,
    isa => 'Str',
    default => sub { $_types->{$_[0]->type}->{filename}; }
);

=attr source_filename

The file from which to extract POD for the content of the README.
The default is the file of the main module of the dist.

=cut

has source_filename => (
    ro, lazy,
    isa => 'Str',
    default => sub { shift->zilla->main_module->name; },
);

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

=cut

has location => (
    ro, lazy,
    isa => enum([qw(build root)]),
    default => sub { $_[0]->__from_name()->[1] || 'build' },
);

=method prune_files

Files with C<location = root> must also be pruned, so that they don't
sneak into the I<next> build by virtue of already existing in the root
dir.

=cut

sub prune_files {
  my ($self) = @_;
  if ($self->location eq 'root') {
      for my $file ($self->zilla->files->flatten) {
          next unless $file->name eq $self->filename;
          $self->log_debug([ 'pruning %s', $file->name ]);
          $self->zilla->prune_file($file);
      }
  }
  return;
}

=method setup_installer

Adds the requested README file to the dist.

=cut

sub setup_installer {
    my ($self) = @_;

    require Dist::Zilla::File::InMemory;

    my $content = $self->get_readme_content();

    my $filename = $self->filename;
    my $file = $self->zilla->files->grep( sub { $_->name eq $filename } )->head;

    if ( $self->location eq 'build' ) {
        if ( $file ) {
            $file->content( $content );
            $self->log("Override $filename in build");
        } else {
            $file = Dist::Zilla::File::InMemory->new({
                content => $content,
                name    => $filename,
            });
            $self->add_file($file);
        }
    }
    elsif ( $self->location eq 'root' ) {
        require File::Slurp;
        my $file = $self->zilla->root->file($filename);
        if (-e $file) {
            $self->log("Override $filename in root");
        }
        File::Slurp::write_file("$file", {binmode => ':raw'}, $content);
    }
    else {
        die "Unknown location specified";
    }

    return;
}

sub _file_from_filename {
    my ($self, $filename) = @_;
    for my $file ($self->zilla->files->flatten) {
        return $file if $file->name eq $filename;
    }
    return; # let moose throw exception if nothing found
}

# Returns a file's POD as a string
sub _extract_pod {
    my $mmcontent = $_[1];

    my $doc = PPI::Document->new(\$mmcontent);
    my $pod_elems = $doc->find('PPI::Token::Pod');
    my $content = "";
    if ($pod_elems) {
        # Concatenation should stringify it
        $content .= PPI::Token::Pod->merge(@$pod_elems);
    }

    return $content;
}

=method get_readme_content

Get the content of the README in the desired format.

=cut

sub get_readme_content {
    my ($self) = shift;
    my $mmcontent = $self->_file_from_filename($self->source_filename)->content;
    my $mmpod = $self->_extract_pod($mmcontent);
    my $parser = $_types->{$self->type}->{parser};
    my $readme_content = $parser->($mmpod);
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

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<rct+perlbug@thompsonclan.org>.

=head1 SEE ALSO

=for :list
* L<Dist::Zilla::Plugin::ReadmeFromPod> - The base for this module
* L<Dist::Zilla::Plugin::ReadmeMarkdownFromPod> - Functionality subsumed by this module
* L<Dist::Zilla::Plugin::CopyReadmeFromBuild> - Functionality partly subsumed by this module
