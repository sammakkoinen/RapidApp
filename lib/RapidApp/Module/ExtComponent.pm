package RapidApp::Module::ExtComponent;

use strict;
use Moose;

extends 'RapidApp::Module';

use RapidApp::Module::Meta::Trait::ExtProp;

use RapidApp::Util qw(:all);

# New: ability to programatically set the Ext panel header/footer
has 'header_template', is => 'ro', isa => 'Maybe[Str]', default => sub{undef};
has 'get_header_html', is => 'ro', isa => 'CodeRef', default => sub {
  sub {
    my $o = shift;
    return $o->header_template ? $o->c->template_render(
      $o->header_template, 
      { c => $o->c, self => $o }
    ) : undef;
  }
};

has 'footer_template', is => 'ro', isa => 'Maybe[Str]', default => sub{undef};
has 'get_footer_html', is => 'ro', isa => 'CodeRef', default => sub {
  sub {
    my $o = shift;
    return $o->footer_template ? $o->c->template_render(
      $o->footer_template, 
      { c => $o->c, self => $o }
    ) : undef;
  }
};

# See below
has '_build_plugins', is => 'ro', isa => 'ArrayRef', default => sub {[]};

# New: informational only property to be added to the ext config and checked
# by the role_checker function below
has 'require_role', is => 'ro', isa => 'Maybe[Str]', default => sub{undef};

# Generic function that can be supplied to call to test if the current request/context
# matches a given 'role' to globally deny access to this component.
# This is for a simple permission API. Note that the 'role' concept is generic to support
# any implementation, such as Catalyst Roles, or anything else. Will receive the context
# object ($c) as the first argument and the 'require_role' value as the second.
# By default, this function is set to a passthrough to a global config param or
# just the standard 'check_any_user_role' function
has 'role_checker', is => 'ro', isa => 'Maybe[CodeRef]', default => sub {
  my $self = shift;
  my $code = try{$self->app->config->{'Model::RapidApp'}{role_checker}} || sub {
    my $c = shift; #<-- expects CONTEXT object
    # This default checker function always returns true if the catalyst
    # context object lacks the check_any_user_role method (which happens
    # when the Authorization plugin isn't loaded). This doesn't stop
    # the developer from supplying a custom role_checker instead which
    # could perform tests based on other criteria, even if there are no
    # users configured (i.e. it could be based on ip address, header, etc)
    return $c && $c->can('check_any_user_role') ? $c->check_any_user_role(@_) : 1;
  }
};

sub BUILD {
  my $self = shift;
  
  # Add the Ext.ux.RapidApp.Plugin.EventHandlers plugin to all AppCmp
  # based objects:
  #$self->add_plugin({ ptype => 'rappeventhandlers' });
  
  
  if(scalar(@{$self->plugins}) > 0) {
    # New: Save the plugins set at BUILD time for later to force them to always
    # be applied to the content.
    @{$self->_build_plugins} = @{$self->plugins};
    $self->add_ONREQUEST_calls_early('_appcmp_enforce_build_plugins');
  }
  
  $self->apply_extconfig( 
    require_role => $self->require_role
  ) if ($self->require_role);

  foreach my $attr ($self->meta->get_all_attributes) {
    $attr->_apply_ext_value($self) if ($attr->does('ExtProp'));
  }

}

sub _appcmp_enforce_build_plugins {
  my $self = shift;
  my %curPlg = map {$_=>1} @{$self->plugins};
  $curPlg{$_} or $self->add_plugin($_) for (@{$self->_build_plugins});
}


sub test_permission {
  my $self = shift;
  my $c = RapidApp->active_request_context;
  (
    $c and
    $self->role_checker and
    $self->require_role and
    # FIXME: only perform the test for valid sessions. This logic already
    # happens (i.e. data is already protected from invalid sessions) and 
    # will need to be updated to consider this new feature
    $c->can('session') and $c->session and #<-- had to add this because 'session_is_valid' below
                                          #    was not returning false (some kind of init issue?)
                                          #    TODO: investigate further...
    $c->can('session_is_valid') and $c->session_is_valid and
    ! $self->role_checker->($c,$self->require_role)
  ) ? 0 : $self->parent_module && $self->parent_module->can('test_permission') 
          ? $self->parent_module->test_permission : 1 
}


sub allowed_content {
  my $self = shift;
  return $self->test_permission ? $self->content : ();
}

sub enforce_permission {
  my $self = shift;
  $self->test_permission and return 1;
  die usererr "Permission denied";
}

sub content {
  my $self = shift;

  $self->enforce_permission;
  
  # ---
  # optionally apply extconfig parameters stored in the stash. This was added to support
  # dynamic dispatch functionality such as a 'RequestMapper' Catalyst controller that might
  # load saved searches by id or name, and might need to apply extra app/module params
  my $apply_extconfig = try{$self->c->stash->{apply_extconfig}};
  $self->apply_extconfig( %$apply_extconfig ) if (ref($apply_extconfig) eq 'HASH');
  # ---

  my $cnf = $self->get_complete_extconfig;
  
  my $header_html = $self->get_header_html->($self);
  $cnf->{headerCfg} = {
    tag => 'div',
    cls => 'panel-borders',
    html => $header_html
  } if ($header_html);
  
  my $footer_html = $self->get_footer_html->($self);
  $cnf->{footerCfg} = {
    tag => 'div',
    cls => 'panel-borders',
    html => $footer_html
  } if ($footer_html);
  
  return $cnf;
}


sub get_complete_extconfig {
  my $self = shift;
  $self->apply_all_extconfig_attrs;
  $self->call_rapidapp_handlers($self->all_ONCONTENT_calls);
  return $self->extconfig;
}

sub apply_all_extconfig_attrs {
  my $self = shift;
  foreach my $attr ($self->meta->get_all_attributes) {
    next unless (
      $attr->does('RapidApp::Role::AppCmpConfigParam') and
      $attr->has_value($self)
    );
    
    $self->apply_extconfig( $attr->name => $attr->get_value($self) );
  }
}


has 'ONCONTENT_calls' => (
  traits    => [ 'Array' ],
  is        => 'ro',
  isa       => 'ArrayRef[RapidApp::Handler]',
  default   => sub { [] },
  handles => {
    all_ONCONTENT_calls    => 'elements',
    add_ONCONTENT_calls    => 'push',
    has_no_ONCONTENT_calls  => 'is_empty',
  }
);
around 'add_ONCONTENT_calls' => __PACKAGE__->add_ONREQUEST_calls_modifier;




has 'extconfig' => (
  traits    => [
    'Hash',
    'RapidApp::Role::PerRequestBuildDefReset'
  ],
  is        => 'ro',
  isa       => 'HashRef',
  default   => sub { {} },
  handles   => {
     apply_extconfig      => 'set',
     get_extconfig_param    => 'get',
     has_extconfig_param    => 'exists',
     has_no_extconfig     => 'is_empty',
     num_extconfig_params  => 'count',
     delete_extconfig_param  => 'delete'
  },
);
# 'config' is being renamed to 'extconfig' 
# These mappings are for backward compatability and will be removed
# at some point. Once they are removed, it will force an API change
# that can be made at any time, since 'extconfig' is already active
sub config             { (shift)->extconfig(@_) }
sub apply_config         { (shift)->apply_extconfig(@_) }
sub get_config_param      { (shift)->get_extconfig_param(@_) }
sub has_config_param      { (shift)->has_extconfig_param(@_) }
sub has_no_config        { (shift)->has_no_extconfig(@_) }
sub num_config_params    { (shift)->num_extconfig_params(@_) }
sub delete_config_param    { (shift)->delete_extconfig_param(@_) }
sub apply_all_config_attrs  { (shift)->apply_all_extconfig_attrs(@_) }




has 'plugins' => (
  traits    => [
    'Array',
    'RapidApp::Role::AppCmpConfigParam',
    'RapidApp::Role::PerRequestBuildDefReset',
  ],
  is        => 'ro',
  isa       => 'ArrayRef',
  default   => sub { [] },
  handles => {
    add_plugin    => 'push',
    has_no_plugins  => 'is_empty',
    plugin_list    => 'uniq'
  }
);


# -- disabled and replaced by "listener_callbacks"
# event_handlers do basically the same thing as "listeners" except it is
# setup as a list instead of a hash, allowing multiple handlers to be
# defined for the same event. Items should be added as ArrayRefs, with
# the first element defining a string representing the event name, and the
# remaining elements representing 1 or more handlers (RapidApp::JSONFunc
# objects). Unlike "listeners" which is a built-in config param associated
# with all Ext.Observable objects, "event_handlers" is a custom param that
# is processed in the Ext.ux.RapidApp.Plugin.EventHandlers plugin which is
# also setup in AppCmp
#has 'event_handlers' => (
#  traits    => [
#    'Array',
#    'RapidApp::Role::AppCmpConfigParam',
#    'RapidApp::Role::PerRequestBuildDefReset',
#  ],
#  is        => 'ro',
#  isa       => 'ArrayRef[ArrayRef]',
#  default   => sub { [] },
#  handles => {
#    add_event_handlers    => 'push',
#    has_no_event_handlers  => 'is_empty',
#  }
#);



has 'listeners' => (
  traits    => [
    'Hash',
    'RapidApp::Role::AppCmpConfigParam',
    'RapidApp::Role::PerRequestBuildDefReset'
  ],
  is        => 'ro',
  isa       => 'HashRef',
  default   => sub { {} },
  handles   => {
     apply_listeners  => 'set',
     get_listener    => 'get',
     has_no_listeners => 'is_empty',
     num_listeners    => 'count',
     delete_listeners  => 'delete'
  },
);



has 'listener_callbacks' => (
  traits    => [
    'Hash',
    'RapidApp::Role::AppCmpConfigParam',
    'RapidApp::Role::PerRequestBuildDefReset'
  ],
  is        => 'ro',
  isa       => 'HashRef[ArrayRef[RapidApp::JSONFunc]]',
  default   => sub { {} },
  handles   => {
     apply_listener_callbacks  => 'set',
     get_listener_callbacks    => 'get',
     has_listener_callbacks    => 'exists'
  },
);
sub add_listener_callbacks {
  my ($self,$event,@funcs) = @_;
  
  my $list = [];
  $list = $self->get_listener_callbacks($event) if ($self->has_listener_callbacks($event));
  
  foreach my $func (@funcs) {
    
    if (ref($func)) {
      push @$list, $func;
    }
    else {
      # Auto convert strings into RapidApp::JSONFunc objects:
      push @$list, RapidApp::JSONFunc->new( raw => 1, func => $func );
    }
  }
  
  return $self->apply_listener_callbacks( $event => $list );  
}



sub add_listener {
  my $self = shift;
  my $event = shift;
  
  $self->add_listener_callbacks($event,@_);
  
  my $handler = RapidApp::JSONFunc->new( raw => 1, func =>
    'function(arg1) {' .
      
      'var cmp = this;' .
      
      'if(arg1.listener_callbacks && !cmp.listener_callbacks) {' .
        'cmp = arg1;' .
      '}' .
      
      'var args = arguments;' .
      'if(cmp.listener_callbacks) {' .
        'var list = this.listener_callbacks["' . $event . '"];' .
        'if(Ext.isArray(list)) {' .
          'Ext.each(list,function(fn) {' .
            'fn.apply(this,args);' .
          '},this);' .
        '}' .
      '}' .
    '}'
  );
  
  return $self->apply_listeners( $event => $handler );
}


sub is_printview {
  my $self = shift;
  my $header = $self->c->req->header('X-RapidApp-View') or return 0;
  return 1 if ($header eq 'print');
  return 0;
}

# Available to derived classes. Can be added to toolbar buttons, etc
sub print_view_button {
  my $self = shift;
  
  my $params = $self->c->req->params;
  delete $params->{_dc};
  
  my $cnf = {
    url => $self->suburl('printview'),
    params => $params
  };
  
  my $json = $self->json->encode($cnf);
  
  return {
    xtype  => 'button',
    text => 'Print View',
    iconCls => 'ra-icon-printer',
    handler => jsfunc 'Ext.ux.RapidApp.winLoadUrlGET.createCallback(' . $json . ')'
  };
}



#### --------------------- ####


no Moose;
#__PACKAGE__->meta->make_immutable;



1;