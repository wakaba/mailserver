use strict;
use warnings;
use Promise;
use POP3Server;
use AnyEvent::Socket;

my $host = '127.0.0.1';
my $port = 4223;

tcp_server $host, $port, sub {
  my ($fh, $remote_host, $remote_port) = @_;
  warn "Remote: $remote_host:$remote_port";

  my $server = POP3Server->new;
  $server->onauth (sub {
    my $self = $_[0];
    if ($self->{user} eq 'user' and $self->{pass} eq 'pass') {
      return 1;
    } else {
      return 0;
    }
  });
  $server->onretr (sub {
    my $id = $_[1];
    if ($id == 1) {
      return "abea\x0D\x0Axyqtea\x0D\x0A.aaa\x0D.\x0A...";
    } else {
      return undef;
    }
  });
  $server->set_fh ($fh);
};

Promise->new (sub { })->to_cv->recv;
