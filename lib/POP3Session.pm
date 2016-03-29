package POP3Session;
use strict;
use warnings;
use AnyEvent::Handle;
use Promise;

sub D ($) { warn "DEBUG: $_[0]\n" }

sub new ($) {
  return bless {state => 'AUTHORIZATION',
                processing => 0,
                lines => [],
                deleted => {}}, $_[0];
} # new

sub onauth ($;$) {
  if (@_ > 1) {
    $_[0]->{onauth} = $_[1];
  }
  return $_[0]->{onauth} || sub { 0 };
} # onauth

sub onstat ($;$) {
  if (@_ > 1) {
    $_[0]->{onstat} = $_[1];
  }
  return $_[0]->{onstat} || sub { {count => 0, size => 0} };
} # onstat

sub onlist ($;$) {
  if (@_ > 1) {
    $_[0]->{onlist} = $_[1];
  }
  return $_[0]->{onlist} || sub { [] };
} # onlist

sub onlist_of ($;$) {
  if (@_ > 1) {
    $_[0]->{onlist_of} = $_[1];
  }
  return $_[0]->{onlist_of} || sub { undef };
} # onlist_of

sub onretr ($;$) {
  if (@_ > 1) {
    $_[0]->{onretr} = $_[1];
  }
  return $_[0]->{onretr} || sub { undef };
} # onretr

sub ondelete ($;$) {
  if (@_ > 1) {
    $_[0]->{ondelete} = $_[1];
  }
  return $_[0]->{ondelete} || sub { 1 };
} # ondelete

sub ondisconnect ($;$) {
  if (@_ > 1) {
    $_[0]->{ondisconnect} = $_[1];
  }
  return $_[0]->{ondisconnect} || sub { };
} # ondisconnect

sub set_fh ($$;$) {
  my $self = $_[0];
  $self->{handle} = AnyEvent::Handle->new
      (fh => $_[1],
       ($_[2] ? (
         tls => 'accept',
         tls_ctx => $_[2],
       ) : ()),
       on_read => sub {
         if ($_[0]->{rbuf} =~ /\A(.*?)\x0D\x0A/s) {
           push @{$self->{lines}}, $1;
           $self->_lines;
           $_[0]->{rbuf} = '';
         } elsif (length $_[0]->{rbuf} > 512) {
           return $self->fatal_error ("Line too long");
         }
       },
       rtimeout => 60,
       on_rtimeout => sub {
         return $self->fatal_error ('Timeout');
       },
       on_error => sub {
         D "error $_[2]";
         $self->{handle}->destroy;
         delete $self->{handle};
         $self->ondisconnect->($self);
       },
       on_eof => sub {
         D "eof";
         $self->{handle}->destroy;
         delete $self->{handle};
         $self->ondisconnect->($self);
       });
  $self->ok ('Hello, what is your USER name?');
} # set_fh

sub ok ($$) {
  my $self = $_[0];
  $self->{handle}->push_write ("+OK $_[1]\x0D\x0A");
} # ok

sub fatal_error ($$) {
  my $self = $_[0];
  D "Fatal error: $_[1]";
  $self->{handle}->push_write ("-ERR $_[1]\x0D\x0A");
  $self->{handle}->push_shutdown;
  $self->{fatal} = 1;
} # fatal_error

sub error ($$) {
  my $self = $_[0];
  D "Error: $_[1]";
  $self->{handle}->push_write ("-ERR $_[1]\x0D\x0A");
} # error

sub _lines ($) {
  my $self = $_[0];
  return if $self->{processing} or $self->{fatal};
  return unless defined $self->{handle};
  return unless @{$self->{lines}};
  return Promise->resolve->then (sub {
    $self->{processing} = 1;
    my $line = shift @{$self->{lines}};
    if ($line =~ s/\A([A-Za-z]{3,4}) //) {
      my $command = $1;
      $command =~ tr/a-z/A-Z/;
      return $self->_command ($command, $line);
    } elsif ($line =~ /\A([A-Za-z]{3,4})\z/) {
      my $command = $1;
      $command =~ tr/a-z/A-Z/;
      return $self->_command ($command, '');
    } else {
      $self->{processing} = 0;
      return $self->fatal_error ("Bad command line");
    }
  })->then (sub { $self->_lines });
} # _lines

sub _command ($$$) {
  my ($self, $command, $args) = @_;
  if ($self->{state} eq 'AUTHORIZATION') {
    if ($command eq 'USER') {
      $self->{user} = $args;
      $self->{processing} = 0;
      return $self->ok ('What is your PASS?');
    } elsif ($command eq 'PASS') {
      if (not defined $self->{user}) {
        $self->{processing} = 0;
        return $self->error ('No USER before PASS');
      }
      $self->{pass} = $args;
      return Promise->resolve->then (sub {
        return $self->onauth->($self);
      })->then (sub {
        if ($_[0]) {
          $self->{state} = 'TRANSACTION';
          $self->{processing} = 0;
          return $self->ok ('Welcome');
        } else {
          $self->{processing} = 0;
          return $self->error ('Bad USER or PASS');
        }
      });
    } elsif ($command eq 'QUIT') {
      $self->ok ('Bye');
      $self->{processing} = 0;
      return $self->{handle}->push_shutdown;
    }
  } elsif ($self->{state} eq 'TRANSACTION') {
    if ($command eq 'STAT') {
      if (length $args) {
        $self->{processing} = 0;
        return $self->error ('Bad arguments');
      }
      return Promise->resolve->then (sub {
        return $self->onstat->($self);
      })->then (sub {
        my $result = $_[0];
        my $count = $result->{count} || 0;
        my $size = $result->{size} || 0;
        $self->ok (sprintf "%d %d", $count, $size);
        return $self->{processing} = 0;
      });
    } elsif ($command eq 'LIST') {
      if ($args =~ /\A[0-9]+\z/) {
        $args = 0+$args;
        if ($self->{deleted}->{$args}) {
          $self->error ("Message not found");
          return $self->{processing} = 0;
        } else {
          return Promise->resolve->then (sub {
            return $self->onlist_of->($self, $args);
          })->then (sub {
            my $result = $_[0];
            if (defined $result) {
              $self->ok (sprintf '%d %d', $args, $result->{size});
            } else {
              $self->error ("Message not found");
            }
            return $self->{processing} = 0;
          });
        }
      } elsif ($args eq '') {
        return Promise->resolve->then (sub {
          return $self->onlist->($self);
        })->then (sub {
          my $result = $_[0];
          $self->ok ('...');
          for (@$result) {
            next if $self->{deleted}->{0+$_->{number}};
            $self->{handle}->push_write (sprintf "%d %d\x0D\x0A", $_->{number}, $_->{size});
          }
          $self->{handle}->push_write (".\x0D\x0A");
          return $self->{processing} = 0;
        });
      } else {
        $self->error ("Bad arguments");
        return $self->{processing} = 0;
      }
    } elsif ($command eq 'UIDL') {
      if ($args =~ /\A[0-9]+\z/) {
        $args = 0+$args;
        if ($self->{deleted}->{$args}) {
          $self->error ("Message not found");
          return $self->{processing} = 0;
        } else {
          return Promise->resolve->then (sub {
            return $self->onlist_of->($self, $args);
          })->then (sub {
            my $result = $_[0];
            if (defined $result) {
              $self->ok (sprintf '%d %s', $args, $result->{id});
            } else {
              $self->error ("Message not found");
            }
            return $self->{processing} = 0;
          });
        }
      } elsif ($args eq '') {
        return Promise->resolve->then (sub {
          return $self->onlist->($self);
        })->then (sub {
          my $result = $_[0];
          $self->ok ('...');
          for (@$result) {
            next if $self->{deleted}->{0+$_->{number}};
            $self->{handle}->push_write (sprintf "%d %s\x0D\x0A", $_->{number}, $_->{id});
          }
          $self->{handle}->push_write (".\x0D\x0A");
          return $self->{processing} = 0;
        });
      } else {
        $self->error ("Bad arguments");
        return $self->{processing} = 0;
      }
    } elsif ($command eq 'RETR') {
      unless ($args =~ /\A[0-9]+\z/) {
        $self->error ("Bad arguments");
        return $self->{processing} = 0;
      }
      $args = 0+$args;
      if ($self->{deleted}->{$args}) {
        $self->error ("Message not found");
        return $self->{processing} = 0;
      }
      return Promise->resolve->then (sub {
        return $self->onretr->($self, $args);
      })->then (sub {
        unless (defined $_[0]) {
          $self->error ("Message not found");
          return $self->{processing} = 0;
        }
        $self->ok ('...');
        pos ($_[0]) = 0;
        while ($_[0] =~ /\G(.*?\x0D\x0A)/gcs) {
          $self->{handle}->push_write ('.') if substr ($1, 0, 1) eq '.';
          $self->{handle}->push_write ($1);
        }
        if ($_[0] =~ /\G(.+)\z/gcs) {
          $self->{handle}->push_write ('.') if substr ($1, 0, 1) eq '.';
          $self->{handle}->push_write ($1);
          $self->{handle}->push_write ("\x0D\x0A");
        }
        $self->{handle}->push_write (".\x0D\x0A");
        return $self->{processing} = 0;
      });
    } elsif ($command eq 'DELE') {
      unless ($args =~ /\A[0-9]+\z/) {
        $self->error ("Bad arguments");
        return $self->{processing} = 0;
      }
      $args = 0+$args;
      if ($self->{deleted}->{$args}) {
        $self->error ("Message not found");
        return $self->{processing} = 0;
      }
      $self->{deleted}->{$args} = 1;
      $self->ok ("Deleted");
      return $self->{processing} = 0;
    } elsif ($command eq 'RSET') {
      unless ($args eq '') {
        $self->error ("Bad arguments");
        return $self->{processing} = 0;
      }
      $self->{deleted} = {};
      $self->ok ('Rolled back');
      return $self->{processing} = 0;
    } elsif ($command eq 'NOOP') {
      $self->ok ('Hi');
      return $self->{processing} = 0;
    } elsif ($command eq 'QUIT') {
      return Promise->resolve->then (sub {
        return $self->ondelete->($self);
      })->then (sub {
        if ($_[0]) {
          $self->ok ('Bye');
        } else {
          $self->error ('Failed to save changes');
        }
        $self->{processing} = 0;
        $self->{fatal} = 1;
        $self->{handle}->push_shutdown;
      });
    }
  }

  $self->error ("Unknown command |$command|");
  return $self->{processing} = 0;
} # _command

1;
