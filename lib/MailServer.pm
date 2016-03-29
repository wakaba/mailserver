package MailServer;
use strict;
use warnings;
use AnyEvent::Socket;
use POP3Session;
use AnyEvent::SMTP::Server;

sub new ($) {
  return bless {}, $_[0];
} # new

sub init_smtp ($%) {
  my ($self, %args) = @_;
  $self->{smtp} = my $smtp = AnyEvent::SMTP::Server->new
      (hostname => $args{host},
       port => $args{port},
       rcpt_validate => $args{onrcpt});
  $smtp->reg_cb (client => $args{onconnect}) if defined $args{onconnect};
  $smtp->reg_cb (disconnect => $args{ondisconnect}) if defined $args{ondisconnect};
  $smtp->reg_cb (mail => $args{onmessage}) if defined $args{onmessage};
  $smtp->start;
} # init_smtp

sub init_pop3 ($%) {
  my ($self, %args) = @_;
  tcp_server $args{host}, $args{port}, sub {
    my ($fh, $remote_host, $remote_port) = @_;
    $self->{pop3} = my $server = POP3Session->new;
    return Promise->resolve->then (sub {
      return $args{onconnect}->($server, {host => $remote_host, port => $remote_port}) if defined $args{onconnect};
    })->then (sub {
      $server->onauth ($args{onauth});
      $server->onretr ($args{onretr});
      $server->onstat ($args{onstat});
      $server->onlist ($args{onlist});
      $server->onlist_of ($args{onlist_of});
      $server->ondelete ($args{ondelete});
      $server->ondisconnect ($args{ondisconnect});
      $server->set_fh ($fh);
    });
  };
} # init_pop3

1;
