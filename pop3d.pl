use strict;
use warnings;
use Promise;
use MailServer;

my $host = '127.0.0.1';
my $port = 4223;
my $smtp_port = 1025;

my $server = MailServer->new;

$server->init_pop3
    (host => $host,
     port => $port,
     onconnect => sub {
       my $remote = $_[1];
       warn "Remote: $remote->{host}:$remote->{port}";
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
       my ($s,$con) = @_;
       warn "Client from $con->{host}:$con->{port} connected\n";
     },
     ondisconnect => sub {
       my ($s,$con) = @_;
       warn "Client from $con->{host}:$con->{port} gone\n";
     },
     onrcpt => sub {
       my ($m,$addr) = @_;
       if ($addr =~ /hoge/) { return 1 } else { return 0, 513, 'Bad recipient.' }
     },
     onmessage => sub {
       my ($s,$mail) = @_;
       warn "Received mail from ($mail->{host}:$mail->{port}) $mail->{from} to $mail->{to}\n$mail->{data}\n";
     });

Promise->new (sub { })->to_cv->recv;
