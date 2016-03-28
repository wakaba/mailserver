package POP3Server;
use strict;
use warnings;
use AnyEvent::Handle;

sub D ($) { warn "DEBUG: $_[0]\n" }

sub new ($) {
  return bless {state => 'AUTHORIZATION'}, $_[0];
} # new

sub onauth ($;$) {
  if (@_ > 1) {
    $_[0]->{onauth} = $_[1];
  }
  return $_[0]->{onauth} || sub { 0 };
} # onauth

sub set_fh ($$) {
  my $self = $_[0];
  $self->{handle} = AnyEvent::Handle->new
      (fh => $_[1],
       on_read => sub {
         if ($_[0]->{rbuf} =~ /\A(.*?)\x0D\x0A/s) {
           my $line = $1;
           if ($line =~ s/\A([A-Za-z]{3,4}) //) {
             my $command = $1;
             $command =~ tr/a-z/A-Z/;
             $self->_command ($command, $line);
           } elsif ($line =~ /\A([A-Za-z]{3,4})\z/) {
             my $command = $1;
             $command =~ tr/a-z/A-Z/;
             $self->_command ($command, '');
           } else {
             return $self->fatal_error ("Bad command line");
           }
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
       },
       on_eof => sub {
         D "eof";
         $self->{handle}->destroy;
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
} # fatal_error

sub error ($$) {
  my $self = $_[0];
  $self->{handle}->push_write ("-ERR $_[1]\x0D\x0A");
} # error

sub _command ($$$) {
  my ($self, $command, $args) = @_;
  if ($self->{state} eq 'AUTHORIZATION') {
    if ($command eq 'USER') {
      $self->{user} = $args;
      return $self->ok ('What is your PASS?');
    } elsif ($command eq 'PASS') {
      if (not defined $self->{user}) {
        return $self->error ('No USER before PASS');
      }
      $self->{pass} = $args;
      if ($self->onauth->($self)) {
        $self->{state} = 'TRANSACTION';
        return $self->ok ('Welcome');
      } else {
        return $self->error ('Bad USER or PASS');
      }
    } elsif ($command eq 'QUIT') {
      $self->ok ('Bye');
      return $self->{handle}->push_shutdown;
    }
  } elsif ($self->{state} eq 'TRANSACTION') {


  }

  $self->error ("Unknown command");
} # _command

1;
