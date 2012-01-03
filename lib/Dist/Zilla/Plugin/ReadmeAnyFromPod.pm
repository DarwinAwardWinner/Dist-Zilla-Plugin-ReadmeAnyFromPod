use strict;
use warnings;

package Dist::Zilla::Plugin::ReadmeAnyFromPod;
# ABSTRACT: Automatically convert POD to a README in any format for Dist::Zilla

use Moose;
use Moose::Autobox;
use MooseX::Has::Sugar;
use Moose::Util::TypeConstraints qw(enum);
use IO::Handle;
use Encode qw( encode );

with 'Dist::Zilla::Role::InstallTool';
with 'Dist::Zilla::Role::FilePruner';

my $types = {
    text => {
        filename => 'README',
        parser => sub {
            my $mmcontent = $_[0];

            require Pod::Text;
            my $parser = Pod::Text->new();
            $parser->output_string( \my $input_content );
            $parser->parse_string_document( $mmcontent );

            my $content;
            if( defined $parser->{encoding} ){
                $content = encode( $parser->{encoding} , $input_content );
            } else {
                $content = $input_content;
            }
            return $content;
        },
    },
    markdown => {
        filename => 'README.mkdn',
        parser => sub {
            my $mmcontent = $_[0];

            require Pod::Markdown;
            my $parser = Pod::Markdown->new();

            require IO::Scalar;
            my $input_handle = IO::Scalar->new(\$mmcontent);

            $parser->parse_from_filehandle($input_handle);
            my $content = $parser->as_markdown();
            return $content;
        },
    },
    pod => {
        filename => 'README.pod',
        parser => sub {
            my $mmcontent = $_[0];

            require Pod::Select;
            require IO::Scalar;
            my $input_handle = IO::Scalar->new(\$mmcontent);
            my $content = '';
            my $output_handle = IO::Scalar->new(\$content);

            my $parser = Pod::Select->new();
            $parser->parse_from_filehandle($input_handle, $output_handle);

            return $content;
        },
    },
    html => {
        filename => 'README.html',
        parser => sub {
            my $mmcontent = $_[0];

            require Pod::Simple::HTML;
            my $parser = Pod::Simple::HTML->new;
            my $content;
            $parser->output_string( \$content );
            $parser->parse_string_document($mmcontent);
            return $content;
        }
    }
};

=attr type

The file format for the readme. Supported types are "text", "markdown", "pod", and "html".

=cut

has type => (
    ro, lazy,
    isa        => enum([keys %$types]),
    default    => sub { 'text' },
);

=attr filename

The file name of the README file to produce. The default depends on the selected format.

=cut

has filename => (
    ro, lazy,
    isa => 'Str',
    default => sub { $types->{$_[0]->type}->{filename}; }
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
    default => sub { 'build' }
);

=method prune_files

Files with C<location = root> must also be pruned, so that they don't
sneak into the I<next> build by virtue of already existing in thr root
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
            $self->zilla->log("Override $filename in build from [ReadmeAnyFromPod]");
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
            $self->zilla->log("Override $filename in root from [ReadmeAnyFromPod]");
        }
        File::Slurp::write_file("$file", {binmode => ':raw'}, $content);
    }
    else {
        die "Unknown location specified";
    }

    return;
}

=method get_readme_content

Get the content of the README in the desired format.

=cut

sub get_readme_content {
    my ($self) = shift;
    my $mmcontent = $self->zilla->main_module->content;
    my $parser = $types->{$self->type}->{parser};
    my $readme_content = $parser->($mmcontent);
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

=head1 DESCRIPTION

Generates a README for your L<Dist::Zilla> powered dist from its
C<main_module> in any of several formats. The generated README can be
included in the build or created in the root of your dist for e.g.
inclusion into version control.

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<rct+perlbug@thompsonclan.org>.

=head1 SEE ALSO

=for :list
* L<Dist::Zilla::Plugin::ReadmeFromPod> - The base for this module
* L<Dist::Zilla::Plugin::ReadmeMarkdownFromPod> - Functionality subsumed by this module
* L<Dist::Zilla::Plugin::CopyReadmeFromBuild> - Functionality partly subsumed by this module

