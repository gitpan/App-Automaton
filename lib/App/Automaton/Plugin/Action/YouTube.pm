package App::Automaton::Plugin::Action::YouTube;

# ABSTRACT: Download module for YouTube videos

use strict;
use warnings;
use Moo;
use File::Spec::Functions;

use Data::Dumper;

sub go {
	my $self = shift;
	my $in = shift;
	my $bits = shift;
	my $d = $in->{debug};
	
	my $target = $in->{target};
	
	foreach my $bit  (@$bits) {
		my @urls = $bit =~ /http[s]?:\/\/www.youtube\.com\/watch\?v=.{11}/g;
		foreach my $url (@urls) {
			my $client = WWWYouTubeDownload->new();
			my $video_data;
			eval { $video_data = $client->prepare_download($url); }; warn "Error with $url\n".$@ if $@;
			#TODO: Report errors
			next unless $video_data;
			my $target_file = catfile($target, $video_data->{title} . '.' . $video_data->{suffix} );
			next if -e $target_file;
			_logger($d, "downloading $url to $target_file");
			eval{$client->download( $url, { filename => $target_file } );}
		}
	}
	
	return 1;
}

sub _logger {
	my $level = shift;
	my $message = shift;
	print "$message\n" if $level;
	return 1;
}

1;

# * NOTE:
# This portion of code, the package "WWWYouTubeDownload", is copied directly from
# the CPAN module WWW::YouTube::Download by XAICRON (Yuji Shimada) and all credit goes to him.
# I copied it here because there is an unfixed issue and it has not been updated on CPAN.
# There are open pull requests waiting on GitHub and once any of them are merged and released via CPAN
# I will go back to just using the CPAN module.

package WWWYouTubeDownload;

use strict;
use warnings;
use 5.008001;

our $VERSION = '0.56';

use Carp qw(croak);
use URI ();
use LWP::UserAgent;
use JSON;
use HTML::Entities qw/decode_entities/;
use HTTP::Request;

$Carp::Internal{ (__PACKAGE__) }++;

use constant DEFAULT_FMT => 18;

my $base_url = 'http://www.youtube.com/watch?v=';

sub new {
    my $class = shift;
    my %args = @_;
    $args{ua} = LWP::UserAgent->new(
        #agent      => __PACKAGE__.'/'.$VERSION,
        parse_head => 0,
    ) unless exists $args{ua};
    bless \%args, $class;
}

for my $name (qw[video_id video_url title user fmt fmt_list suffix]) {
    no strict 'refs';
    *{"get_$name"} = sub {
        use strict 'refs';
        my ($self, $video_id) = @_;
        croak "Usage: $self->get_$name(\$video_id|\$watch_url)" unless $video_id;
        my $data = $self->prepare_download($video_id);
        return $data->{$name};
    };
}

sub playback_url {
    my ($self, $video_id, $args) = @_;
    croak "Usage: $self->playback_url('[video_id|video_url]')" unless $video_id;
    $args ||= {};

    my $data = $self->prepare_download($video_id);
    my $fmt  = $args->{fmt} || $data->{fmt} || DEFAULT_FMT;
    my $video_url = $data->{video_url_map}{$fmt}{url} || croak "this video has not supported fmt: $fmt";

    return $video_url;
}

sub download {
    my ($self, $video_id, $args) = @_;
    croak "Usage: $self->download('[video_id|video_url]')" unless $video_id;
    $args ||= {};

    my $data = $self->prepare_download($video_id);

    my $fmt = $args->{fmt} || $data->{fmt} || DEFAULT_FMT;

    my $video_url = $data->{video_url_map}{$fmt}{url} || croak "this video has not supported fmt: $fmt";
    $args->{filename} ||= $args->{file_name};
    my $filename = $self->_format_filename($args->{filename}, {
        video_id   => $data->{video_id},
        title      => $data->{title},
        user       => $data->{user},
        fmt        => $fmt,
        suffix     => $data->{video_url_map}{$fmt}{suffix} || _suffix($fmt),
        resolution => $data->{video_url_map}{$fmt}{resolution} || '0x0',
    });

    $args->{cb} = $self->_default_cb({
        filename  => $filename,
        verbose   => $args->{verbose},
        overwrite => defined $args->{overwrite} ? $args->{overwrite} : 1,
    }) unless ref $args->{cb} eq 'CODE';

    my $res = $self->ua->get($video_url, ':content_cb' => $args->{cb});
    croak "!! $video_id download failed: ", $res->status_line if $res->is_error;
}

sub _format_filename {
    my ($self, $filename, $data) = @_;
    return "$data->{video_id}.$data->{suffix}" unless defined $filename;
    $filename =~ s#{([^}]+)}#$data->{$1} || "{$1}"#eg;
    return $filename;
}

sub _is_supported_fmt {
    my ($self, $video_id, $fmt) = @_;
    my $data = $self->prepare_download($video_id);
    $data->{video_url_map}{$fmt}{url} ? 1 : 0;
}

sub _default_cb {
    my ($self, $args) = @_;
    my ($file, $verbose, $overwrite) = @$args{qw/filename verbose overwrite/};

    croak "file exists! $file" if -f $file and !$overwrite;
    open my $wfh, '>', $file or croak $file, " $!";
    binmode $wfh;

    print "Downloading `$file`\n" if $verbose;
    return sub {
        my ($chunk, $res, $proto) = @_;
        print $wfh $chunk; # write file

        if ($verbose || $self->{verbose}) {
            my $size = tell $wfh;
            my $total = $res->header('Content-Length');
            printf "%d/%d (%.2f%%)\r", $size, $total, $size / $total * 100;
            print "\n" if $total == $size;
        }
    };
}

sub prepare_download {
    my ($self, $video_id) = @_;
    croak "Usage: $self->prepare_download('[video_id|watch_url]')" unless $video_id;
    $video_id = $self->video_id($video_id);

    return $self->{cache}{$video_id} if ref $self->{cache}{$video_id} eq 'HASH';

    my $content       = $self->_get_content($video_id);
    my $title         = $self->_fetch_title($content);
    my $user          = $self->_fetch_user($content);
    my $video_url_map = $self->_fetch_video_url_map($content);

    my $fmt_list = [];
    my $sorted = [
        map {
            push @$fmt_list, $_->[0]->{fmt};
            $_->[0]
        } sort {
            $b->[1] <=> $a->[1]
        } map {
            my $resolution = $_->{resolution};
            $resolution =~ s/(\d+)x(\d+)/$1 * $2/e;
            [ $_, $resolution ]
        } values %$video_url_map,
    ];

    my $hq_data = $sorted->[0];

    return $self->{cache}{$video_id} = {
        video_id      => $video_id,
        video_url     => $hq_data->{url},
        title         => $title,
        user          => $user,
        video_url_map => $video_url_map,
        fmt           => $hq_data->{fmt},
        fmt_list      => $fmt_list,
        suffix        => $hq_data->{suffix},
        resolution    => $hq_data->{resolution},
    };
}

sub _fetch_title {
    my ($self, $content) = @_;

    my ($title) = $content =~ /<meta name="title" content="(.+?)">/ or return;
    return decode_entities($title);
}

sub _fetch_user {
    my ($self, $content) = @_;

    my ($user) = $content =~ /<span class="yt-user-name\s+?" dir="ltr">([^<]+)<\/span>/ or return;
    return decode_entities($user);
}

sub _fetch_video_url_map {
    my ($self, $content) = @_;

    my $args = $self->_get_args($content);
    unless ($args->{fmt_list} and $args->{url_encoded_fmt_stream_map}) {
        croak 'failed to find video urls';
    }

    my $fmt_map     = _parse_fmt_map($args->{fmt_list});
    my $fmt_url_map = _parse_stream_map($args->{url_encoded_fmt_stream_map});

    my $video_url_map = +{
        map {
            $_->{fmt} => $_,
        } map +{
            fmt        => $_,
            resolution => $fmt_map->{$_},
            url        => $fmt_url_map->{$_},
            suffix     => _suffix($_),
        }, keys %$fmt_map
    };

    return $video_url_map;
}

sub _get_content {
    my ($self, $video_id) = @_;

    my $url = "$base_url$video_id";

    my $req = HTTP::Request->new;
    $req->method('GET');
    $req->uri($url);
    $req->header('Accept-Language' => 'en-US');

    my $res = $self->ua->request($req);
    croak "GET $url failed. status: ", $res->status_line if $res->is_error;

    return $res->content;
}

sub _get_args {
    my ($self, $content) = @_;

    my $data;
    for my $line (split "\n", $content) {
        next unless $line;
        if ($line =~ /the uploader has not made this video available in your country/i) {
            croak 'Video not available in your country';
        }
        elsif ($line =~ /^.+ytplayer\.config\s*=\s*({.*})/) {
            ($data, undef) = JSON->new->utf8(1)->decode_prefix($1);
            last;
        }
    }

    croak 'failed to extract JSON data' unless $data->{args};

    return $data->{args};
}

sub _parse_fmt_map {
    my $param = shift;
    my $fmt_map = {};
    for my $stuff (split ',', $param) {
        my ($fmt, $resolution) = split '/', $stuff;
        $fmt_map->{$fmt} = $resolution;
    }

    return $fmt_map;
}

sub _sigdecode {
    my @s = @_;

    # based on youtube_dl/extractor/youtube.py from yt-dl.org
    if (@s == 92) {
	return ($s[25], @s[3..24], $s[0], @s[26..41], $s[79], @s[43..78], $s[91], @s[80..82]);
    } elsif (@s == 90) {
	return ($s[25], @s[3..24], $s[2], @s[26..39], $s[77], @s[41..76], $s[89], @s[78..80]);
    } elsif (@s == 88) {
        return ($s[48], reverse(@s[68..81]), $s[82], reverse(@s[63..66]), $s[85],
                reverse(@s[49..61]), $s[67], reverse(@s[13..47]), $s[3],
                reverse(@s[4..11]), $s[2], $s[12]);
    } elsif (@s == 87) {
        return (@s[4..22], $s[86], @s[24..84]);
    } elsif (@s == 86) {
        return (@s[2..62], $s[82], @s[64..81], $s[63]);
    } elsif (@s == 85) {
       return (@s[2..7], $s[0], @s[9..20], $s[65], @s[22..64], $s[84], @s[66..81], $s[21]);
    } elsif (@s == 84) {
        return (reverse(@s[37..83]), $s[2], reverse(@s[27..35]), $s[3],
                reverse(@s[4..25]), $s[26]);
    } elsif (@s == 83) {
        return ($s[6], @s[3..5], $s[33], @s[7..23], $s[0], @s[25..32], $s[53], @s[34..52], $s[24], @s[54..82]);
    } elsif (@s == 82) {
        return ($s[36], reverse(@s[68..79]), $s[81], reverse(@s[41..66]), $s[33],
                reverse(@s[37..39]), $s[40], $s[35], $s[0], $s[67],
                reverse(@s[1..32]), $s[34]);
    } elsif (@s == 81) {
        return ($s[56], reverse(@s[57..79]), $s[41], reverse(@s[42..55]), $s[80],
		reverse(@s[35..40]), $s[0], reverse(@s[30..33]), $s[34],
		reverse(@s[10..28]), $s[29], reverse(@s[1..8]), $s[9]);
    } elsif (@s == 79) {
        return ($s[54], reverse(@s[55..77]), $s[39], reverse(@s[40..53]), $s[78],
		reverse(@s[35..38]), $s[0], reverse(@s[30..33]), $s[34],
		reverse(@s[10..28]), $s[29], reverse(@s[1..8]), $s[9]);
    }

    return ();    # fail
}

sub _getsig {
    my $sig = shift;
    croak 'Unable to find signature' unless $sig;
    my @sig = _sigdecode(split(//, $sig));
    croak "Unable to decode signature $sig of length " . length($sig) unless @sig;
    return join('', @sig);
}

sub _parse_stream_map {
    my $param       = shift;
    my $fmt_url_map = {};
    for my $stuff (split ',', $param) {
        my $uri = URI->new;
        $uri->query($stuff);
        my $query = +{ $uri->query_form };
		$fmt_url_map->{$query->{itag}} = $query->{url};
    }

    return $fmt_url_map;
}

sub ua {
    my ($self, $ua) = @_;
    return $self->{ua} unless $ua;
    croak "Usage: $self->ua(\$LWP_LIKE_OBJECT)" unless eval { $ua->isa('LWP::UserAgent') };
    $self->{ua} = $ua;
}

sub _suffix {
    my $fmt = shift;
    return $fmt =~ /43|44|45/    ? 'webm'
         : $fmt =~ /18|22|37|38/ ? 'mp4'
         : $fmt =~ /13|17/       ? '3gp'
         :                         'flv'
    ;
}

sub video_id {
    my ($self, $stuff) = @_;
    return unless $stuff;
    if ($stuff =~ m{/.*?[?&;!](?:v|video_id)=([^&#?=/;]+)}) {
        return $1;
    }
    elsif ($stuff =~ m{/(?:e|v|embed)/([^&#?=/;]+)}) {
        return $1;
    }
    elsif ($stuff =~ m{#p/(?:u|search)/\d+/([^&?/]+)}) {
        return $1;
    }
    elsif ($stuff =~ m{youtu.be/([^&#?=/;]+)}) {
        return $1;
    }
    else {
        return $stuff;
    }
}

sub playlist_id {
    my ($self, $stuff) = @_;
    return unless $stuff;
    if ($stuff =~ m{/.*?[?&;!]list=([^&#?=/;]+)}) {
        return $1;
    }
    elsif ($stuff =~ m{^\s*([FP]L[\w\-]+)\s*$}) {
        return $1;
    }
    return $stuff;
}

sub user_id {
    my ($self, $stuff) = @_;
    return unless $stuff;
    if ($stuff =~ m{/user/([^&#?=/;]+)}) {
        return $1;
    }
    return $stuff;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Automaton::Plugin::Action::YouTube - Download module for YouTube videos

=head1 VERSION

version 0.143580

=head1 SYNOPSIS

This module is intended to be used from within the App::Automaton application.

It identifies and downloads links from youtube.com.

=head1 METHODS

=over 4

=item go

Executes the plugin. Expects input: conf as hashref, queue as arrayref

=back

=head1 SEE ALSO

L<App::Automaton>

=head1 AUTHOR

Michael LaGrasta <michael@lagrasta.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Michael LaGrasta.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
