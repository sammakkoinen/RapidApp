package RapidApp::Error;

use Moose;

use overload '""' => \&as_string; # to-string operator overload
use Data::Dumper;
use DateTime;
use Devel::StackTrace::WithLexicals;

sub dieConverter {
	die ref $_[0]? $_[0] : capture(join ' ', @_);
}

=head2 $err= capture( $something )

This function attempts to capture the details of some other exception object (or just a string)
and pull them into the fields of a RapidApp::Error.  This allows all code in RapidApp to convert
anything that happens to get caught into a Error object so that the handy methods like "trace"
and "isUserError" can be used.

=cut
sub capture {
	my $errObj= shift;
	if (blessed($errObj)) {
		return $errObj if $errObj->isa('RapidApp::Error');
		
		# TODO: come up with more comprehensive data collection from unknown classes
		my $hash= {};
		$hash->{message} ||= $errObj->message if $errObj->can('message');
		$hash->{trace}   ||= $errObj->trace   if $errObj->can('trace');
		return RapidApp::Error->new($hash);
	}
	else if (ref $errObj eq 'HASH') {
		# TODO: more processing here...  but not sure when we'd make use of this anyway
		return RapidApp::Error->new($errObj);
	}
	else {
		my $msg= ''.$errObj;
		my @lines= split /[\n\r]/, $msg;
		if ($lines[0] =~ /^(.*?) at ([^ ]+\.p[lm].*)/) {
			$msg= $1;
			# TODO: we might want to build a fake StackTrace object using $2... but only if it is more relevant than our current stack
		}
		return RapidApp::Error->new({ message => $msg });
	}
}

has 'message_fn' => ( is => 'rw', isa => 'CodeRef' );
has 'message' => ( is => 'rw', isa => 'Str', lazy_build => 1 );
sub _build_message {
	my $self= shift;
	return $self->message_fn;
}

has 'userMessage_fn' => ( is => 'rw', isa => 'CodeRef' );
has 'userMessage' => ( is => 'rw', isa => 'Str', lazy_build => 1 );
sub _build_userMessage {
	my $self= shift;
	return defined $self->userMessage_fn? $self->userMessage_fn->() : undef;
}

sub isUserError {
	return defined $self->userMessage || defined $self->userMessage_fn;
}

has 'timestamp' => ( is => 'rw', isa => 'Int', default => sub { time } );
has 'dateTime' => ( is => 'rw', isa => 'DateTime', lazy_build => 1 );
sub _build_dateTime {
	my $self= shift;
	my $d= DateTime->new($self->timestamp);
	$d->set_time_zone('UTC');
	return $d;
}

has 'srcLoc' => ( is => 'rw', lazy_build => 1 );
sub _build_srcLoc {
	my $self= shift;
	my $frame= $self->trace->frame(0);
	return defined $frame? $frame->filename . ' line ' . $frame->line : undef;
}

has 'data' => ( is => 'rw', isa => 'HashRef' );
has 'cause' => ( is => 'rw' );

has 'trace' => ( is => 'rw' );
sub _build_trace {
	# if catalyst is in debug mode, we capture a FULL stack trace
	#my $c= RapidApp::ScopedGlobals->catalystInstance;
	#if (defined $c && $c->debug) {
	#	$self->{trace}= Devel::StackTrace::WithLexicals->new(ignore_class => [ __PACKAGE__ ]);
	#}
	return Devel::StackTrace->new(ignore_class => [__PACKAGE__]);
}

around 'BUILDARGS' => sub {
	my ($orig, $class, @args)= @_;
	my $params= ref $args[0] eq 'HASH'? $args[0]
		: (scalar(@args) == 1? { message => $args[0] } : { @args } );
	
	return $class->$orig($params);
}

sub BUILD {
	my $self= shift;
	defined $self->message_fn || $self->has_message or die "Require one of message or message_fn";
	$params->trace # can't wait for this one to be lazy
}

sub dump {
	my $self= shift;
	
	# start with the readable messages
	my $result= $self->message."\n";
	defined $self->userMessage
		and $result.= "User Message: ".$self->userMessage."\n";
	
	$result.= ' on '.$self->dateTime->ymd.' '.$self->dateTime->hms."\n";
	
	defined $self->data
		and $result.= Dumper([$self->data], ["Data"])."\n";
	
	defined $self->trace
		and $result.= 'Stack: '.$self->trace."\n";
	
	defined $self->cause
		and $result.= 'Caused by: '.(blessed $self->cause && $self->cause->can('dump')? $self->cause->dump : ''.$self->cause);
	
	return $result;
}

sub as_string {
	return (shift)->message;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;