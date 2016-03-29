use strict;
use warnings;
use Promise;
use MailServer;

my $host = '127.0.0.1';
my $pop3_port = 4223;
my $smtp_port = 1025;

sub L (%) {
  my @time = gmtime;
  my $t = sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $time[5]+1900, $time[4]+1, $time[3], $time[2], $time[1], $time[0];
  print "time:$t";
  while (@_) {
    print "\t", shift, ":", shift;
  }
  print "\n";
} # L

my $server = MailServer->new;

$server->init_pop3
    (host => $host,
     port => $pop3_port,
     onconnect => sub {
       my $remote = $_[1];
       my $id = time * 100 + int rand 100;
       $_[0]->{server_session_id} = $id;
       L action => 'session_started',
           protocol => 'pop3',
           remote_host => $remote->{host},
           remote_port => $remote->{port},
           session_id => $id;
     },
     ondisconnect => sub {
       L action => 'session_end',
           session_id => $_[0]->{server_session_id};
     },
     onauth => sub {
       my $self = $_[0];
       if ($self->{user} eq 'user' and $self->{pass} eq 'pass') {
         return 1;
       } else {
         return 0;
       }
     },
     onretr => sub {
       my $id = $_[1];
       if ($id == 1) {
         return "abea\x0D\x0Axyqtea\x0D\x0A.aaa\x0D.\x0A...";
       } else {
         return undef;
       }
     },
     onstat => sub {

     },
     onlist => sub {
     },
     onlist_of => sub {

     },
     ondelete => sub {
     });

$server->init_smtp
    (host => $host,
     port => $smtp_port,
     onconnect => sub {
       my ($s, $con) = @_;
       my $id = time * 100 + int rand 100;
       $s->{server_session_id} = $id;
       L action => 'session_started',
           protocol => 'smtp',
           remote_host => $con->{host},
           remote_port => $con->{port},
           session_id => $id;
     },
     ondisconnect => sub {
       my ($s, $con) = @_;
       L action => 'session_end',
           protocol => 'smtp',
           session_id => $s->{server_session_id};
     },
     onrcpt => sub {
       my ($m,$addr) = @_;
       if ($addr =~ /hoge/) { return 1 } else { return 0, 513, 'Bad recipient.' }
     },
     onmessage => sub {
       my ($s,$mail) = @_;
       warn "Received mail from ($mail->{host}:$mail->{port}) $mail->{from} to $mail->{to}\n$mail->{data}\n";
     });

L action => 'server_started',
    protocol => 'smtp',
    local_host => $host,
    local_port => $smtp_port;
L action => 'server_started',
    protocol => 'pop3',
    local_host => $host,
    local_port => $pop3_port;

Promise->new (sub { })->to_cv->recv;
