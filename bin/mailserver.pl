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
     onstat => sub {
       my $result = {count => 0, size => 0};
       for ($db_path->children (qr/\A[1-9][0-9]+\z/)) {
         $result->{count}++;
         $result->{size} += -s $_->stat;
       }
       return $result;
     },
     onlist => sub {
       my $result = [];
       for ($db_path->children (qr/\A[1-9][0-9]+\z/)) {
         $_ =~ /([0-9]+)\z/;
         push @$result, {number => $1, size => -s $_->stat};
       }
       return $result;
     },
     onlist_of => sub {
       my $number = $_[1];
       return undef unless $number =~ /\A[1-9][0-9]+\z/;
       my $path = $db_path->child ($number);
       my $file = Promised::File->new_from_path ($path);
       return $file->is_file->then (sub {
         return undef unless $_[0];
         return $file->stat->then (sub {
           return undef unless defined $_[0];
           return {size => -s $_[0]};
         });
       });
     },
     onretr => sub {
       my $number = $_[1];
       return undef unless $number =~ /\A[1-9][0-9]+\z/;
       my $path = $db_path->child ($number);
       my $file = Promised::File->new_from_path ($path);
       return $file->is_file->then (sub {
         return undef unless $_[0];
         return $file->read_byte_string;
       });
     },
     ondelete => sub {
       my $server = $_[0];
       my $p = [];
       for my $number (keys %{$server->{deleted}}) {
         next unless $number =~ /\A[1-9][0-9]+\z/;
         my $path = $db_path->child ($number);
         my $file = Promised::File->new_from_path ($path);
         push @$p, $file->is_file->then (sub {
           return $file->remove_tree;
         })->then (sub {
           L action => 'message_deleted',
             message_number => $number,
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
                 message_number => $number,
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
