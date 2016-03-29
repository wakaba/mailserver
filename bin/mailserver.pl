use strict;
use warnings;
use Promise;
use MailServer;
use Path::Tiny;
use Promised::File;
use JSON::PS;

my $conf_file_name = shift or die "Usage: $0 conf-file\n";
my $conf_path = path ($conf_file_name);
my $Config = json_bytes2perl $conf_path->slurp;

my $base_path = $conf_path->parent->absolute;
my $db_path = path ($Config->{db_dir})->absolute ($base_path);
$db_path->mkpath;

if (defined $Config->{tls}) {
  $Config->{tls}->{key} = path (delete $Config->{tls}->{key_file})->absolute ($base_path)->slurp
      if defined $Config->{tls}->{key_file};
  $Config->{tls}->{cert} = path (delete $Config->{tls}->{cert_file})->absolute ($base_path)->slurp
      if defined $Config->{tls}->{cert_file};
  $Config->{tls}->{ca_cert} = path (delete $Config->{tls}->{ca_file})->absolute ($base_path)->slurp
      if defined $Config->{tls}->{ca_file};
}

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

sub messages () {
  my $result = [];
  my $by_number = {};
  my $n = 1;
  for ($db_path->children (qr/\A[1-9][0-9]+\z/)) {
    $_ =~ /([0-9]+)\z/;
    my $num = $n++;
    push @$result,
        $by_number->{$num} = {number => $num, id => $1, size => -s $_->stat};
  }
  return {all => $result, map => $by_number};
} # messages

my $server = MailServer->new;

$server->init_pop3
    (host => $Config->{host},
     port => $Config->{pop3_port},
     tls => $Config->{tls},
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
           protocol => 'pop3',
           session_id => $_[0]->{server_session_id};
     },
     onauth => sub {
       my $self = $_[0];
       if (defined $Config->{user} and
           defined $Config->{password} and
           $self->{user} eq $Config->{user} and
           $self->{pass} eq $Config->{password}) {
         L action => 'session_auth', result => 'ok', user => $self->{user};
         return 1;
       } else {
         L action => 'session_auth', result => 'ng', user => $self->{user};
         return 0;
       }
     },
     onstat => sub {
       $_[0]->{server_messages} ||= messages;
       my $result = {count => 0, size => 0};
       for (@{$_[0]->{server_messages}->{all}}) {
         $result->{count}++;
         $result->{size} += $_->{size};
       }
       return $result;
     },
     onlist => sub {
       $_[0]->{server_messages} ||= messages;
       return $_[0]->{server_messages}->{all};
     },
     onlist_of => sub {
       $_[0]->{server_messages} ||= messages;
       return $_[0]->{server_messages}->{map}->{$_[1]}; # or undef
     },
     onretr => sub {
       $_[0]->{server_messages} ||= messages;
       my $m = $_[0]->{server_messages}->{map}->{$_[1]}; # or undef
       return undef unless defined $m;
       my $path = $db_path->child ($m->{id});
       my $file = Promised::File->new_from_path ($path);
       return $file->is_file->then (sub {
         return undef unless $_[0];
         return $file->read_byte_string;
       });
     },
     ondelete => sub {
       return unless defined $_[0]->{server_messages};
       my $server = $_[0];
       my $p = [];
       for my $number (keys %{$server->{deleted}}) {
         my $m = $_[0]->{server_messages}->{map}->{$number};
         next unless defined $m;
         my $path = $db_path->child ($m->{id});
         my $file = Promised::File->new_from_path ($path);
         push @$p, $file->is_file->then (sub {
           return $file->remove_tree;
         })->then (sub {
           L action => 'message_deleted',
             message_id => $m->{id},
             session_id => $server->{server_session_id};
         });
       }
       return Promise->all ($p)->then (sub { 1 });
     });

$server->init_smtp
    (host => $Config->{host},
     port => $Config->{smtp_port},
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
       my ($m, $addr) = @_;
       my $allowed = 0;
       for (@{$Config->{allowed_domains}}) {
         if ($addr =~ /\@\Q$_\E\z/) {
           $allowed = 1;
           last;
         }
       }
       return 0, 513, 'Bad recipient' unless $allowed;
       return 1;
     },
     onmessage => sub {
       my ($s, $mail) = @_;
       my $try; $try = sub {
         my $number = time * 100 + int rand 100;
         my $path = $db_path->child ($number);
         my $file = Promised::File->new_from_path ($path);
         return $file->is_file->then (sub {
           if ($_[0]) {
             return $try->();
           } else {
             my $c = sub {
               my $s = $_[0];
               $s =~ s/[\x0D\x0A\x09]/ /g;
               return $s;
             };
             my $trace = $c->("Return-Path: <$mail->{from}>")."\x0D\x0A";
             my @time = gmtime;
             my $time = sprintf '%02d %s %04d %02d:%02d:%02d GMT',
                 $time[3],
                 qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)[$time[4]],
                 $time[5]+1900, $time[2], $time[1], $time[0];
             my $to = "<$mail->{to}->[0]>";
             if (@{$mail->{to}} > 1) {
               $to .= ' (' . (join ' ', map { "<$_>" } @{$mail->{to}}[1..$#{$mail->{to}}]) . ')';
             }
             $trace .= $c->("Received: from $mail->{helo} ($mail->{host}) by $Config->{host} with SMTP id $number for $to; $time")."\x0D\x0A";
             return $file->write_byte_string ($trace.$mail->{data})->then (sub {
               L action => 'message_saved',
                 message_id => $number,
                 session_id => $s->{server_session_id},
                 mail_from => $mail->{from},
                 mail_to => join ',', @{$mail->{to}};
             });
           }
         });
       };
       return $try->()->then (sub { undef $try });
     });

L action => 'server_started',
    protocol => 'smtp',
    local_host => $Config->{host},
    local_port => $Config->{smtp_port},
    db_dir => $db_path;
L action => 'server_started',
    protocol => 'pop3',
    local_host => $Config->{host},
    local_port => $Config->{pop3_port},
    db_dir => $db_path;

Promise->new (sub { })->to_cv->recv;
