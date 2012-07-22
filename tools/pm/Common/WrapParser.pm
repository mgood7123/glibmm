# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# gmmproc - Common::WrapParser module
#
# Copyright 2011, 2012 glibmm development team
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
#

package Common::WrapParser;

use strict;
use warnings;
use v5.10;

use IO::File;

use Common::CxxFunctionInfo;
use Common::CFunctionInfo;
use Common::SignalInfo;
use Common::Util;
use Common::SectionManager;
use Common::Shared;
use Common::Output;
use Common::TypeInfo::Local;
use Common::WrapInit;
use constant
{
  # stages
  'STAGE_HG' => 0,
  'STAGE_CCG' => 1,
  'STAGE_INVALID' => 2,
  # gir entry
  'GIR_RECORD' => 0,
  'GIR_CLASS' => 1,
  'GIR_ANY' => 2,
  # temp wrap init
  'TEMP_WRAP_INIT_EXTRA_INCLUDES' => 1,
  'TEMP_WRAP_INIT_DEPRECATED' => 4,
  'TEMP_WRAP_INIT_CPP_CONDITION' => 5
};

###
### NOT SURE ABOUT THE CODE BELOW
###

# TODO: check if we can avoid using it.
# Look back for a Doxygen comment.  If there is one,
# remove it from the output and return it as a string.
sub extract_preceding_documentation ($)
{
  my ($self) = @_;
  my $outputter = $$self{objOutputter};
  my $out = \@{$$outputter{out}};

  my $comment = '';

  if ($#$out >= 2)
  {
    # steal the last three tokens
    my @back = splice(@$out, -3);
    local $_ = join('', @back);

    # Check for /*[*!] ... */ or //[/!] comments.  The closing */ _must_
    # be the last token of the previous line.  Apart from this restriction,
    # anything else should work, including multi-line comments.

    if (m#\A/\s*\*(?:\*`|`!)(.+)'\*/\s*\z#s or m#\A\s*//`[/!](.+)'\s*\z#s)
    {
      $comment = '`' . $1;
      $comment =~ s/\s*$/'/;
    }
    else
    {
      # restore stolen tokens
      push(@$out, @back);
    }
  }

  return $comment;
}

# TODO: probably implement this. I am not sure.
# void _on_wrap_corba_method()
sub _on_wrap_corba_method ($)
{
  my ($self) = @_;

  $self->_extract_bracketed_text;
  # my $objOutputter = $$self{objOutputter};

  # return unless ($self->check_for_eof());

  # my $filename = $$self{filename};
  # my $line_num = $$self{line_num};

  # my $str = $self->_extract_bracketed_text();
  # my @args = string_split_commas($str);

  # my $entity_type = "method";

  # if (!$$self{in_class})
  #   {
  #     print STDERR "$filename:$line_num:_WRAP macro encountered outside class\n";
  #     return;
  #   }

  # my $objCppfunc;

  # # handle first argument
  # my $argCppMethodDecl = $args[0];
  # if ($argCppMethodDecl !~ m/\S/s)
  # {
  #   print STDERR "$filename:$line_num:_WRAP_CORBA_METHOD: missing prototype\n";
  #   return;
  # }

  # # Parse the method decaration and build an object that holds the details:
  # $objCppfunc = &Function::new($argCppMethodDecl, $self);
  # $objOutputter->output_wrap_corba_method($filename, $line_num, $objCppfunc);
}

###
### NOT SURE ABOUT THE CODE ABOVE
###

sub _handle_get_args_results ($$)
{
  my ($self, $results) = @_;

  if (defined $results)
  {
    my $errors = $results->[0];
    my $warnings = $results->[1];
    my $fatal = 0;

    if (defined $errors)
    {
      foreach my $error (@{$errors})
      {
        my $param = $error->[0];
        my $message = $error->[1];

        $self->fixed_error_non_fatal (join ':', $param, $message);
      }
      $fatal = 1;
    }
    if (defined $warnings)
    {
      foreach my $warning (@{$warnings})
      {
        my $param = $warning->[0];
        my $message = $warning->[1];

        $self->fixed_warning (join ':', $param, $message);
      }
    }

    if ($fatal)
    {
# TODO: throw an exception or something.
      exit 1;
    }
  }
}

sub _extract_token ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;
  my $results = Common::Shared::extract_token $tokens;
  my $token = $results->[0];
  my $add_lines = $results->[1];

  $self->inc_line_num ($add_lines);
  return $token;
}

sub _peek_token ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;

  while (@{$tokens})
  {
    my $token = $tokens->[0];

    # skip empty tokens
    if (not defined $token or $token eq '')
    {
      shift @{$tokens};
    }
    else
    {
      return $token;
    }
  }

  return '';
}

sub _extract_bracketed_text ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;
  my $result = Common::Shared::extract_bracketed_text $tokens;

  if (defined $result)
  {
    my $string = $result->[0];
    my $add_lines = $result->[1];

    $self->inc_line_num ($add_lines);
    return $string;
  }

  $self->fixed_error ('Hit eof when extracting bracketed text.');
}

sub _extract_members
{
  my ($object, $substs, $new_style, $identifier_prefixes) = @_;
  my $member_count = $object->get_g_member_count;
  my @all_members = ();

  for (my $iter = 0; $iter < $member_count; ++$iter)
  {
    my $member = $object->get_g_member_by_index ($iter);
    my $name = undef;

    if ($new_style)
    {
      $name = uc ($member->get_a_name ());
    }
    else
    {
      # For old style enums we have to use full names without global
      # prefix. Otherwise we can get some conflicts like for SURROGATE
      # that is in both UnicodeType and UnicodeBreakType.
      foreach my $prefix (@{$identifier_prefixes})
      {
        my $to_remove = $prefix . '_';

        $name = $member->get_a_c_identifier ();
        if ($name =~ /^$to_remove/)
        {
          $name =~ s/^$to_remove//;
          last;
        }
      }
    }

    my $value = $member->get_a_value ();

    foreach my $pair (@{$substs})
    {
      $name =~ s#$pair->[0]#$pair->[1]#;
      $value =~ s#$pair->[0]#$pair->[1]#;
    }
    push @all_members, [$name, $value];
  }

  return \@all_members;
}

sub _on_string_with_delimiters ($$$$)
{
  my ($self, $start, $end, $what) = @_;
  my $tokens = $self->get_tokens;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;
  my @out = ($start);

  while (@{$tokens})
  {
    my $token = $self->_extract_token;

    push @out, $token;
    if ($token eq $end)
    {
      $section_manager->append_string_to_section ((join '', @out), $main_section);
      return;
    }
  }
  $self->fixed_error ('Hit eof while in ' . $what . '.');
}

sub _on_ending_brace ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;
  my @strings = ();
  my $slc = 0;
  my $mlc = 0;

  while (@{$tokens})
  {
    my $token = $self->_extract_token;

    push @strings, $token;
    if ($slc)
    {
      if ($token eq "\n")
      {
        last;
      }
    }
    elsif ($mlc)
    {
      if ($token eq "*/")
      {
        last;
      }
    }
    elsif ($token eq '//')
    {
      # usual case: } // namespace Foo
      $slc = 1;
    }
    elsif ($token eq '/*')
    {
      # usual case: } /* namespace Foo */
      $mlc = 1;
    }
    elsif ($token eq "\n")
    {
      last;
    }
    elsif ($token =~ /^\s+$/)
    {
      # got nonwhitespace, non plain comment token
      # removing it from strings and putting it back to tokens, so it will be processed later.
      pop @strings;
      unshift @{$tokens}, $token;
      last;
    }
  }
  $section_manager->append_string_to_section ((join '', @strings, "\n"), $main_section);
}

sub _get_gir_stack ($)
{
  my ($self) = @_;

  return $self->{'gir_stack'};
}

sub _push_gir_generic ($$$)
{
  my ($self, $gir_stuff, $gir_type) = @_;
  my $gir_stack = $self->_get_gir_stack;

  push @{$gir_stack}, [$gir_type, $gir_stuff];
}

sub _push_gir_record ($$)
{
  my ($self, $gir_record) = @_;

  $self->_push_gir_generic ($gir_record, GIR_RECORD);
}

sub _push_gir_class ($$)
{
  my ($self, $gir_class) = @_;

  $self->_push_gir_generic  ($gir_class, GIR_CLASS);
}

sub _get_gir_generic ($$)
{
  my ($self, $gir_type) = @_;
  my $gir_stack = $self->_get_gir_stack;

  if (@{$gir_stack})
  {
    my $gir_desc = $gir_stack->[-1];

    if ($gir_desc->[0] == $gir_type or $gir_type == GIR_ANY)
    {
      return $gir_desc->[1];
    }
  }

  return undef;
}

sub _get_gir_record ($)
{
  my ($self) = @_;

  return $self->_get_gir_generic (GIR_RECORD);
}

sub _get_gir_class ($)
{
  my ($self) = @_;

  return $self->_get_gir_generic (GIR_CLASS);
}

sub _get_gir_entity ($)
{
  my ($self) = @_;

  return $self->_get_gir_generic (GIR_ANY);
}

sub _pop_gir_entity ($)
{
  my ($self) = @_;
  my $gir_stack = $self->_get_gir_stack;

  pop @{$gir_stack};
}

sub _get_c_stack ($)
{
  my ($self) = @_;

  return $self->{'c_stack'};
}

sub _push_c_class ($$)
{
  my ($self, $c_class) = @_;
  my $c_stack = $self->_get_c_stack;

  push @{$c_stack}, $c_class;
}

sub _pop_c_class ($)
{
  my ($self) = @_;
  my $c_stack = $self->_get_c_stack;

  pop @{$c_stack};
}

# TODO: public
sub get_c_class ($)
{
  my ($self) = @_;
  my $c_stack = $self->_get_c_stack;

  if (@{$c_stack})
  {
    return $c_stack->[-1];
  }
  return undef;
}

sub _get_prop_name ($$$$)
{
  my ($self, $gir_class, $c_param_name, $cxx_param_name) = @_;
  my $c_prop_name = $c_param_name;

  $c_prop_name =~ s/_/-/g;

  my $gir_property = $gir_class->get_g_property_by_name ($c_prop_name);

  unless (defined $gir_property)
  {
    my $cxx_prop_name = $cxx_param_name;

    $cxx_prop_name =~ s/_/-/g;
    $gir_property = $gir_class->get_g_property_by_name ($cxx_prop_name);

    unless (defined $gir_property)
    {
# TODO: error in proper, fixed line.
      die;
    }
  }

  return $gir_property->get_a_name;
}

###
### HANDLERS BELOW
###

sub _on_open_brace ($)
{
  my ($self) = @_;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;

  $self->inc_level;
  $section_manager->append_string_to_section ('{', $main_section);
}

sub add_wrap_init_entry
{
  my ($self, $entry) = @_;
  my $wrap_init_entries = $self->get_wrap_init_entries ();

  push (@{$wrap_init_entries}, $entry);
}

sub _on_close_brace ($)
{
  my ($self) = @_;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;
  my $namespace_levels = $self->get_namespace_levels;
  my $namespaces = $self->get_namespaces;
  my $level = $self->get_level;
  my $class_levels = $self->get_class_levels;
  my $classes = $self->get_classes;

  $section_manager->append_string_to_section ('}', $main_section);

  # check if we are closing the class brace
  if (@{$class_levels} and $class_levels->[-1] == $level)
  {
    if (@{$classes} == 1)
    {
      my $section = Common::Output::Shared::get_section $self, Common::Sections::H_AFTER_FIRST_CLASS;

      $self->_on_ending_brace;
      $section_manager->append_section_to_section ($section, $main_section);
    }

    my $temp_wrap_init_stack = $self->_get_temp_wrap_init_stack ();

    # check if we are closing the class brace which had temporary wrap init
    if (@{$temp_wrap_init_stack})
    {
      my $temp_wrap_init = $temp_wrap_init_stack->[-1];
      my $wrap_init_level = $temp_wrap_init->[0];

      if ($wrap_init_level == $level)
      {
        shift (@{$temp_wrap_init});
        pop (@{$temp_wrap_init_stack});

        my $wrap_init_entry = Common::WrapInit::GObject->new (@{$temp_wrap_init});

        $self->add_wrap_init_entry ($wrap_init_entry);
      }
      elsif ($wrap_init_level > $level)
      {
# TODO: internal error I guess. This wrap init should already be popped.
        die;
      }
    }

    pop @{$class_levels};
    pop @{$classes};
    $self->_pop_gir_entity;
  }
  # check if we are closing the namespace brace
  elsif (@{$namespace_levels} and $namespace_levels->[-1] == $level)
  {
    if (@{$namespaces} == 1)
    {
      my $section = Common::Output::Shared::get_section $self, Common::Sections::H_AFTER_FIRST_NAMESPACE;

      $self->_on_ending_brace;
      $section_manager->append_section_to_section ($section, $main_section);
    }

    pop @{$namespaces};
    pop @{$namespace_levels};
  }

  $self->dec_level;
}

sub _on_string_literal ($)
{
  my ($self) = @_;

  $self->_on_string_with_delimiters ('"', '"', 'string');
}

sub _on_comment_cxx ($)
{
  my ($self) = @_;

  $self->_on_string_with_delimiters ('//', "\n", 'C++ comment');
}

# TODO: look at _on_comment_doxygen - something similar has to
# TODO continued: be done here.
sub _on_comment_doxygen_single ($)
{
  my ($self) = @_;

  $self->_on_string_with_delimiters ('///', "\n", 'Doxygen single line comment');
}

sub _on_comment_c ($)
{
  my ($self) = @_;

  $self->_on_string_with_delimiters ('/*', '*/', 'C comment');
}

# TODO: use the commented code.
sub _on_comment_doxygen ($)
{
  my ($self) = @_;

  $self->_on_string_with_delimiters ('/**', '*/', 'Doxygen multiline comment');

#  my $tokens = $self->get_tokens;
#  my @out =  ('/**');
#
#  while (@{$tokens})
#  {
#    my $token = $self->_extract_token;
#
#    if ($token eq '*/')
#    {
#      push @out, '*';
#      # Find next non-whitespace token, but remember whitespace so that we
#      # can print it if the next real token is not _WRAP_SIGNAL
#      my @whitespace = ();
#      my $next_token = $self->_peek_token;
#      while ($next_token !~ /\S/)
#      {
#        push @whitespace, $self->_extract_token;
#        $next_token = $self->_peek_token;
#      }
#
#      # If the next token is a signal, do not close this comment, to merge
#      # this doxygen comment with the one from the signal.
#      if ($next_token eq '_WRAP_SIGNAL')
#      {
#        # Extract token and process
#        $self->_extract_token;
#        # Tell wrap_signal to merge automatically generated comment with
#        # already existing comment. This is why we do not close the comment
#        # here.
#        return $self->_on_wrap_signal_after_comment(\@out);
#      }
#      else
#      {
#        # Something other than signal follows, so close comment normally
#        # and append whitespace we ignored so far.
#        push @out, '/', @whitespace;
#        return join '', @out;
#      }
#
#      last;
#    }
#
#    push @out, $token;
#  }
#  $self->fixed_error ('Hit eof while in doxygen comment.');
}

# TODO: We have to just ignore #m4{begin,end}, and check for
# TODO continued: _CONVERSION macros inside.
sub _on_m4_section ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;

  $self->fixed_warning ('Deprecated.');

  while (@{$tokens})
  {
    return if ($self->_extract_token eq '#m4end');
  }

  $self->fixed_error ('Hit eof when looking for #m4end.');
}

# TODO: We have to just ignore #m4, and check for _CONVERSION
# TODO continued: macros inside.
sub _on_m4_line ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;

  $self->fixed_warning ('Deprecated.');

  while (@{$tokens})
  {
    return if ($self->_extract_token eq "\n");
  }

  $self->fixed_error ('Hit eof when looking for newline');
}

sub _on_defs ($)
{
  my ($self) = @_;

  $self->fixed_warning ('Deprecated.');
  $self->_extract_bracketed_text;
}

# TODO: implement it.
sub _on_ignore ($)
{
  my ($self) = @_;

  $self->fixed_warning ('Not yet implemented.');
  $self->_extract_bracketed_text;
#  my @args = split(/\s+|,/,$str);
#  foreach (@args)
#  {
#    next if ($_ eq "");
#    GtkDefs::lookup_function($_); #Pretend that we've used it.
#  }
}

# TODO: implement it.
sub _on_ignore_signal ($)
{
  my ($self) = @_;

  $self->fixed_warning ('Not yet implemented.');
  $self->_extract_bracketed_text;
#  $str = Common::Util::string_trim($str);
#  $str = Common::Util::string_unquote($str);
#  my @args = split(/\s+|,/,$str);
#  foreach (@args)
#  {
#    next if ($_ eq "");
#    GtkDefs::lookup_signal($$self{c_class}, $_); #Pretend that we've used it.
#  }
}

# TODO: move it elsewhere, remove it later.
sub _maybe_warn_about_refreturn ($$$$)
{
  my ($self, $ret_transfer, $refreturn, $cxx_type) = @_;

  return if ($cxx_type !~ /^(const\s+)?(?:Glib::)?RefPtr/);

  if ($ret_transfer == Common::TypeInfo::Common::TRANSFER_FULL and $refreturn)
  {
    $self->fixed_warning ('refreturn given but annotation says that transfer is already full - which is wrong? (refreturn is ignored anyway.)');
  }
  elsif ($ret_transfer == Common::TypeInfo::Common::TRANSFER_NONE and not $refreturn)
  {
    $self->fixed_warning ('There is no refreturn, but annotation says that transfer is none - which is wrong? (refreturn would be ignored anyway.)');
  }
}

# TODO: move it elsewhere, remove it later.
sub _maybe_warn_about_errthrow ($$$)
{
  my ($self, $throws, $errthrow) = @_;

  if (not $throws and $errthrow)
  {
    $self->fixed_warning ('errthrow given but annotation says that no error here is thrown - which is wrong? (errthrow is ignored anyway.)');
  }
  elsif ($throws and not $errthrow)
  {
    $self->fixed_warning ('There is no errthrow but annotation says that an error can be thrown here - which is wrong? (errthrow would be ignored anyway.)');
  }
}

sub _on_wrap_method ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_method_decl = shift @args;
  my $c_function_name = shift @args;
  my $deprecated = 0;
  my $refreturn = 0;
  my $constversion = 0;
  my $errthrow = 0;
  my $ifdef = undef;
  my $silence_gir_quirk = 0;
  my $setup =
  {
    'b(deprecated)' => \$deprecated,
# TODO: probably obsolete, maybe inform that some annotation
# TODO continued: could be added to C sources.
    'ob(refreturn)' => \$refreturn,
    'b(constversion)' => \$constversion,
    'ob(errthrow)' => \$errthrow,
    's(ifdef)' => \$ifdef,
    'b(silence_gir_quirk)' => \$silence_gir_quirk
  };

  $self->_handle_get_args_results (Common::Shared::get_args \@args, $setup);

  my $cxx_function = Common::CxxFunctionInfo->new_from_string ($cxx_method_decl);
  my $gir_entity = $self->_get_gir_entity;

  unless (defined $gir_entity)
  {
    $self->fixed_error ('Macro outside class.');
  }

# TODO: Check if we have any function outside C class wrapped
# TODO continued: in C++ class. If not then getting the
# TODO continued: namespace is not needed.
  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $module_namespace = (split (/-/, $module))[0];
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $gir_namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $gir_namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my $gir_func = $gir_entity->get_g_method_by_name ($c_function_name);
  my $is_a_function = 0;

  unless (defined $gir_func)
  {
    $gir_func = $gir_entity->get_g_function_by_name ($c_function_name);
    $is_a_function = 1;

    unless (defined $gir_func)
    {
      $gir_func = $gir_namespace->get_g_function_by_name ($c_function_name);

      # Check if we are wrapping a C constructor with
      # _WRAP_METHOD. Sensible only for static methods.
      if (not defined ($gir_func) and $cxx_function->get_static ())
      {
        $gir_func = $gir_entity->get_g_constructor_by_name ($c_function_name);
      }

      unless (defined ($gir_func))
      {
        $self->fixed_error ('No such method: ' . $c_function_name);
      }
    }
  }

  my $c_function = Common::CFunctionInfo->new_from_gir ($gir_func, $self);
  my $c_param_types = $c_function->get_param_types ();
  my $c_param_transfers = $c_function->get_param_transfers ();

  # Workaround for wrapping gir <function> as a method - gir omits
  # "this" parameter in <method>, but not in <function> - we have to
  # get rid of it ourselves.
  # TODO: Should we check the deleted parameter?
  if (not $cxx_function->get_static () and $is_a_function)
  {
    shift (@{$c_param_types});
    shift (@{$c_param_transfers});
  }

  if ($cxx_function->get_static () and not $is_a_function)
  {
    if (index ($c_function_name, '_new') >= 0)
    {
      # Workaround for wrapping gir <method> which should be
      # <constructor>. This happens where constructor takes an instance
      # of the type it instatiates. That one needs fixing in gir files,
      # not here.
      my $guessed_c_type = join ('', 'const ', $gir_entity->get_a_c_type (), '*');
      my $message = 'This is marked as <method> instead of <constructor>. Please fix it in C library by adding (constructor) annotation after constructor_name (here: "' . $c_function_name . ': (constructor)"). For now working it around by prepending "' . $guessed_c_type . '" parameter type.';

      $self->fixed_warning ($message);
      unshift (@{$c_param_types}, $guessed_c_type);
      unshift (@{$c_param_transfers}, Common::TypeInfo::Common::TRANSFER_NONE);
    }
    else
    {
      # Workaround for rare cases of functions like
      # g_bytes_hash(gconstpointer bytes) which are treated by
      # gobject-introspection as methods instead of functions. I do
      # not know whether this should be fixed in gobject-introspection
      # and whether we can just assume that prepended C parameter is
      # going to be the same as first C++ parameter. Probably not.
      # Wrapping this function manually is the safest bet.
      unless ($silence_gir_quirk)
      {
        my $message = 'This is marked as <method> in GIR, but is wrapped as static method. You probably know what you are doing, so I am assuming that you are not wrapping a constructor and that the first parameter of C function is of the same type as the one of C++ static method. If this is right then add "silence_gir_quirk" option to this macro. Otherwise try either filing a bug to appriopriate product (be it C library or gmmproc) or wrapping this method manually.';

        $self->fixed_warning ($message);
      }
      unshift (@{$c_param_types}, $cxx_function->get_param_types ()->[0]);
      unshift (@{$c_param_transfers}, Common::TypeInfo::Common::TRANSFER_NONE);
    }
  }

  my $ret_transfer = $c_function->get_return_transfer;
  my $throws = $c_function->get_throws;

# TODO: remove the ifs below after possible bugs in
# TODO continued: wrappers/annotations are fixed.
  $self->_maybe_warn_about_refreturn ($ret_transfer, $refreturn, $cxx_function->get_return_type ());
  $self->_maybe_warn_about_errthrow ($throws, $errthrow);

  Common::Output::Method::output ($self,
                                  $cxx_function->get_static,
                                  $cxx_function->get_return_type,
                                  $cxx_function->get_name,
                                  $cxx_function->get_param_types,
                                  $cxx_function->get_param_names,
                                  $cxx_function->get_param_values,
                                  $cxx_function->get_param_nullables,
                                  $cxx_function->get_param_out_index,
                                  $cxx_function->get_const,
                                  $constversion,
                                  $deprecated,
                                  $ifdef,
                                  $c_function->get_return_type,
                                  $ret_transfer,
                                  $c_function->get_name,
                                  $c_param_types,
                                  $c_param_transfers,
                                  $throws);
}

# TODO: implement it.
sub _on_wrap_method_docs_only ($)
{
  my ($self) = @_;

  $self->_extract_bracketed_text;
  $self->fixed_warning ('Not yet implemented.');
  # my $objOutputter = $$self{objOutputter};

  # return unless ($self->check_for_eof());

  # my $filename = $$self{filename};
  # my $line_num = $$self{line_num};

  # my $str = $self->_extract_bracketed_text();
  # my @args = string_split_commas($str);

  # my $entity_type = "method";

  # if (!$$self{in_class})
  #   {
  #     print STDERR "$filename:$line_num:_WRAP macro encountered outside class\n";
  #     return;
  #   }

  # my $objCfunc;

  # # handle first argument
  # my $argCFunctionName = $args[0];
  # $argCFunctionName = Common::Util::string_trim($argCFunctionName);

  # # Get the C function's details:

  # # Checks that it's not empty or contains whitespace
  # if ($argCFunctionName =~ m/^\S+$/s)
  # {
  #   #c-name. e.g. gtk_clist_set_column_title
  #   $objCfunc = GtkDefs::lookup_function($argCFunctionName);

  #   if(!$objCfunc) #If the lookup failed:
  #   {
  #     $objOutputter->output_wrap_failed($argCFunctionName, "method defs lookup failed (1)");
  #     return;
  #   }
  # }

  # # Extra ref needed?
  # $$objCfunc{throw_any_errors} = 0;
  # while($#args >= 1) # If the optional ref/err arguments are there.
  # {
  #   my $argRef = Common::Util::string_trim(pop @args);
  #   if($argRef eq "errthrow")
  #   {
  #     $$objCfunc{throw_any_errors} = 1;
  #   }
  # }

  # my $commentblock = "";
  # $commentblock = DocsParser::lookup_documentation($argCFunctionName, "");

  # $objOutputter->output_wrap_meth_docs_only($filename, $line_num, $commentblock);
}

# TODO: Split the common part from it and make two methods
# TODO continued: with merging doxycomment and without it.
# TODO: Implement it actually.
sub _on_wrap_signal ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_method_decl = shift @args;
  my $c_signal_str = shift @args;
  my $deprecated = 0;
  my $refreturn = 0;
  my $ifdef = undef;
  my $dhs_disabled = 0;
  my $custom_c_callback = 0;
  my $custom_signal_handler = 0;
  my $setup =
  {
    'b(deprecated)' => \$deprecated,
# TODO: probably obsolete, maybe inform that some annotation
# TODO continued: could be added to C sources.
    'ob(refreturn)' => \$refreturn,
    's(ifdef)' => \$ifdef,
    'b(no_default_handler)' => \$dhs_disabled,
    'b(custom_c_callback)' => \$custom_c_callback,
    'b(custom_signal_handler)' => \$custom_signal_handler
  };

  $self->_handle_get_args_results (Common::Shared::get_args \@args, $setup);

  if ($c_signal_str =~ /_/ or $c_signal_str !~ /$".*"^/)
  {
    $self->fixed_warning ('Second parameter should be like C string (in double quotes) with dashes instead of underlines - e.g. "activate-link".');
  }

  $c_signal_str =~ s/_/-/g;
  $c_signal_str =~ s/"//g;

  my $c_signal_name = $c_signal_str;

  $c_signal_name =~ s/-/_/g;

  my $cxx_function = Common::CxxFunctionInfo->new_from_string ($cxx_method_decl);
  my $gir_class = $self->_get_gir_class;

  unless (defined $gir_class)
  {
    $self->fixed_error ('Macro outside class.');
  }

  my $gir_signal = $gir_class->get_g_glib_signal_by_name ($c_signal_str);

  unless (defined $gir_signal)
  {
    $self->fixed_error ('No such signal: ' . $c_signal_str);
  }

  my $c_signal = Common::SignalInfo->new_from_gir ($gir_signal, $self);
  my $ret_transfer = $c_signal->get_return_transfer;

# TODO: remove the ifs below after possible bugs in
# TODO continued: wrappers/annotations are fixed.
  $self->_maybe_warn_about_refreturn ($ret_transfer, $refreturn, $cxx_function->get_return_type ());

# TODO: Add custom_signal_handler.
  Common::Output::Signal::output $self,
                                 $ifdef,
                                 $c_signal->get_return_type,
                                 $ret_transfer,
                                 $c_signal_name,
                                 $c_signal->get_name,
                                 $c_signal->get_param_types,
                                 $c_signal->get_param_names,
                                 $c_signal->get_param_transfers,
                                 $cxx_function->get_return_type,
                                 $cxx_function->get_name,
                                 $cxx_function->get_param_types,
                                 $cxx_function->get_param_names,
                                 $custom_c_callback,
                                 !$dhs_disabled;
}

sub _on_wrap_property ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $prop_c_name = shift @args;
  my $prop_cxx_type = shift @args;

  # Catch useless parameters.
  $self->_handle_get_args_results (Common::Shared::get_args \@args, {});

  if ($prop_c_name =~ /_/ or $prop_c_name !~ /^"\w+"$/)
  {
    $self->fixed_warning ('First parameter should be like C string (in double quotes) with dashes instead of underlines - e.g. "g-name-owner".');
  }

  $prop_c_name =~ s/_/-/g;
  $prop_c_name =~ s/"//g;

  my $prop_cxx_name = $prop_c_name;

  $prop_c_name =~ s/-/_/g;

  my $gir_class = $self->_get_gir_class;

  unless ($gir_class)
  {
    $self->fixed_error ('Outside Glib::Object subclass.');
  }

  my $gir_property = $gir_class->get_g_property_by_name ($prop_c_name);

  unless ($gir_property)
  {
    $self->fixed_error ('No such property in gir: "' . $prop_c_name . '".');
  }

  my $construct_only = $gir_property->get_a_construct_only;
  my $readable = $gir_property->get_a_readable;
  my $writable = $gir_property->get_a_writable;
# TODO: probably not needed.
  my $transfer = $gir_property->get_a_transfer_ownership;
  my $read_only = 0;
  my $write_only = 0;

  if ($construct_only and not $readable)
  {
    $self->fixed_error ('Tried to wrap write-only and construct-only property');
  }

  Common::Output::Property::output $self,
                                   $construct_only,
                                   $readable,
                                   $writable,
                                   $prop_cxx_type,
                                   $prop_cxx_name,
                                   $prop_c_name;
}

sub _on_wrap_vfunc ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_method_decl = shift @args;
  my $c_vfunc_name = shift @args;

  if ($c_vfunc_name !~ /^\w+$/)
  {
    $self->fixed_warning ('Second parameter should be like a name of C vfunc. No dashes, no double quotes.');
  }

  $c_vfunc_name =~ s/-/_/g;
  $c_vfunc_name =~ s/"//g;

  my $deprecated = 0;
  my $refreturn = 0;
  my $errthrow = 0;
  my $ifdef = undef;
  my $custom_vfunc = 0;
  my $custom_vfunc_callback = 0;
  my $setup =
  {
    'b(deprecated)' => \$deprecated,
# TODO: probably obsolete, maybe inform that some annotation
# TODO continued: could be added to C sources.
    'ob(refreturn)' => \$refreturn,
    'ob(refreturn_ctype)' => undef,
    'ob(errthrow)' => $errthrow,
    's(ifdef)' => \$ifdef,
    'b(custom_vfunc)' => \$custom_vfunc,
    'b(custom_vfunc_callback)' => \$custom_vfunc_callback
  };

  $self->_handle_get_args_results (Common::Shared::get_args \@args, $setup);

  my $cxx_function = Common::CxxFunctionInfo->new_from_string ($cxx_method_decl);
  my $gir_class = $self->_get_gir_class;

  unless (defined $gir_class)
  {
    $self->fixed_error ('Macro outside Glib::Object subclass.');
  }

  my $gir_vfunc = $gir_class->get_g_virtual_method_by_name ($c_vfunc_name);

  unless (defined $gir_vfunc)
  {
    $self->fixed_error ('No such virtual method: ' . $c_vfunc_name);
  }

  my $c_vfunc = Common::CFunctionInfo->new_from_gir ($gir_vfunc, $self);
  my $ret_transfer = $c_vfunc->get_return_transfer;
  my $throws = $c_vfunc->get_throws;

# TODO: remove the ifs below after possible bugs in
# TODO continued: wrappers/annotations are fixed.
  $self->_maybe_warn_about_refreturn ($ret_transfer, $refreturn, $cxx_function->get_return_type ());
  $self->_maybe_warn_about_errthrow ($throws, $errthrow);

  Common::Output::VFunc::output $self,
                                $ifdef,
                                $c_vfunc->get_return_type,
                                $ret_transfer,
                                $c_vfunc->get_name,
                                $c_vfunc->get_param_types,
                                $c_vfunc->get_param_names,
                                $c_vfunc->get_param_transfers,
                                $cxx_function->get_return_type,
                                $cxx_function->get_name,
                                $cxx_function->get_param_types,
                                $cxx_function->get_param_names,
                                $cxx_function->get_const,
                                $custom_vfunc,
                                $custom_vfunc_callback,
                                $throws;
}

sub _on_wrap_ctor ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_method_decl = shift @args;
  my $c_constructor_name = shift @args;

  # Catch useless parameters.
  $self->_handle_get_args_results (Common::Shared::get_args \@args, {});

  my $cxx_function = Common::CxxFunctionInfo->new_from_string ($cxx_method_decl);
  my $gir_class = $self->_get_gir_class;

  unless (defined $gir_class)
  {
    $self->fixed_error ('Macro outside Glib::Object subclass.');
  }

  my $gir_constructor = $gir_class->get_g_constructor_by_name ($c_constructor_name);

  unless (defined $gir_constructor)
  {
    $self->fixed_error ('No such constructor: ' . $c_constructor_name);
  }

  my $c_constructor = Common::CFunctionInfo->new_from_gir ($gir_constructor, $self);
  my $c_param_names = $c_constructor->get_param_names;
  my $cxx_param_names = $cxx_function->get_param_names;
  my $c_params_count = @{$c_param_names};
  my $cxx_params_count = @{$cxx_param_names};

  die if $c_params_count != $cxx_params_count;

  my @c_prop_names = map { $self->_get_prop_name ($gir_class, $c_param_names->[$_], $cxx_param_names->[$_]) } 0 .. ($c_params_count - 1);

  Common::Output::Ctor::wrap_ctor ($self,
                                   $c_constructor->get_param_types,
                                   $c_constructor->get_param_transfers,
                                   \@c_prop_names,
                                   $cxx_function->get_param_types,
                                   $cxx_function->get_param_names,
                                   $cxx_function->get_param_values);
}

sub _on_wrap_create ($)
{
  my ($self) = @_;
  my $params = Common::Shared::parse_params $self->_extract_bracketed_text;
  my $types = [];
  my $names = [];
  my $values = [];

  foreach my $param (@{$params})
  {
    push @{$types}, $param->{'type'};
    push @{$names}, $param->{'name'};
    push (@{$values}, $param->{'value'});
  }

  Common::Output::Ctor::wrap_create ($self,
                                     $types,
                                     $names,
                                     $values);
}

sub _on_wrap_enum ($)
{
  my ($self) = @_;
  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $module_namespace = (split (/-/, $module))[0];
  my $repository = $repositories->get_repository ($module);
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text);

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_type = Common::Util::string_trim(shift @args);
  my $c_type = Common::Util::string_trim(shift @args);
  my @sed = ();
  my $new_style = 0;
  my $setup =
  {
    'ob(NO_GTYPE)' => undef,
    'a(sed)' => \@sed,
    'os(get_type_func)' => undef,
    'b(new_style)' => \$new_style
  };

  $self->_handle_get_args_results (Common::Shared::get_args \@args, $setup);

  my @substs = ();

  for my $subst (@sed)
  {
    if ($subst =~ /^\s*s#([^#]*)#([^#]*)#\s*$/)
    {
      push (@substs, [$1, $2]);
    }
    else
    {
      $self->fixed_warning ('sed:Badly formed value - delimiters have to be hashes (#).');
    }
  }

  my $flags = 0;
  my $enum = $namespace->get_g_enumeration_by_name ($c_type);

  unless (defined $enum)
  {
    $enum = $namespace->get_g_bitfield_by_name ($c_type);
    $flags = 1;
    unless (defined $enum)
    {
      $self->fixed_error ('No such enumeration or bitfield: `' . $c_type . '\'.');
    }
  }

  my @identifier_prefixes = split (',', $namespace->get_a_c_identifier_prefixes ());
  my $gir_gtype = $enum->get_a_glib_get_type;
  my $members = _extract_members ($enum, \@substs, $new_style, \@identifier_prefixes);

  Common::Output::Enum::output ($self,
                                $cxx_type,
                                $members,
                                $flags,
                                $gir_gtype,
                                $new_style);
}

# TODO: move it outside handlers section
sub _get_c_includes ($)
{
  my ($repository) = @_;
  my $c_includes_count = $repository->get_g_c_include_count ();
  my $c_includes = [];

  foreach my $index (0 .. ($c_includes_count - 1))
  {
    my $gir_c_include = $repository->get_g_c_include_by_index ($index);
    my $include = join ('', '<', $gir_c_include->get_a_name (), '>');

    push (@{$c_includes}, $include);
  }

  return $c_includes;
}

sub _on_wrap_gerror ($)
{
  my ($self) = @_;
  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $module_namespace = (split (/-/, $module))[0];
  my $repository = $repositories->get_repository ($module);
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text);

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_type = Common::Util::string_trim (shift @args);
  my $c_type = Common::Util::string_trim (shift @args);
  my $enum = $namespace->get_g_enumeration_by_name ($c_type);
  my @identifier_prefixes = split (',', $namespace->get_a_c_identifier_prefixes ());

  if (@args)
  {
    my $arg = $args[0];

    if ($arg ne 'NO_GTYPE' and $arg !~ /^\s*s#[^#]+#[^#]*#\s*$/ and $arg !~ /^\s*get_type_func=.*$/)
    {
      $self->fixed_warning ('Domain parameter is deprecated.');
      shift @args;
    }
  }

  my @sed = ();
  my $new_style = 0;
  my $setup =
  {
    'ob(NO_GTYPE)' => undef,
    'a(sed)' => \@sed,
    'os(get_type_func)' => undef,
    'b(new_style)' => \$new_style
  };

  $self->_handle_get_args_results (Common::Shared::get_args \@args, $setup);

  my @substs = ();

  for my $subst (@sed)
  {
    if ($subst =~ /^\s*s#([^#]*)#([^#]*)#\s*$/)
    {
      push (@substs, [$1, $2]);
    }
    else
    {
      $self->fixed_warning ('sed:Badly formed value - delimiters have to be hashes (#).');
    }
  }

  unless (defined $enum)
  {
    $self->fixed_error ('No such enumeration: `' . $c_type . '\'.');
  }

  my $gir_gtype = $enum->get_a_glib_get_type;
  my $gir_domain = $enum->get_a_glib_error_domain;
  #my $members = _extract_members ($enum, \@substs, $new_style, \@identifier_prefixes);
  # We are passing true for "new style" members - we are not afraid of name collisions
  # in GError code enums. Also, it seems that the same was done in old gmmproc.
  my $members = _extract_members ($enum, \@substs, 1, \@identifier_prefixes);

  Common::Output::GError::output ($self,
                                  $cxx_type,
                                  $members,
                                  $gir_domain,
                                  $gir_gtype,
                                  $new_style);

  my $c_includes = _get_c_includes ($repository);
  my $cxx_includes = [join ('', '"', $self->get_base (), '.h"')];
# TODO: Add deprecated option to _WRAP_GERROR
  my $deprecated = 0;
# TODO: Add "C preprocessor condition" option to _WRAP_GERROR
  my $cpp_condition = 0;
# TODO: Add "Extra include" option to _WRAP_GERROR
  my $extra_includes = [];
  my $complete_cxx_type = Common::Output::Shared::get_complete_cxx_type ($self);
  my $wrap_init_entry = Common::WrapInit::GError->new ($extra_includes,
                                                       $c_includes,
                                                       $cxx_includes,
                                                       $deprecated,
                                                       $cpp_condition,
                                                       $self->get_mm_module (),
                                                       $gir_domain,
                                                       $complete_cxx_type);

  $self->add_wrap_init_entry ($wrap_init_entry);
}

sub _on_implements_interface ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $interface = shift @args;
  my $ifdef = undef;
  my $setup =
  {
    's(ifdef)' => \$ifdef
  };

  $self->_handle_get_args_results (Common::Shared::get_args \@args, $setup);

  Common::Output::GObject::implements_interface $self, $interface, $ifdef;
}

sub _on_class_generic ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args < 2)
  {
    $self->fixed_error ('Too few parameters.');
  }

  my $cxx_type = shift @args;
  my $c_type = shift @args;

  # Catch useless parameters.
  $self->_handle_get_args_results (Common::Shared::get_args \@args, {});

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my $gir_record = $namespace->get_g_record_by_name ($c_type);

  unless (defined $gir_record)
  {
    $self->fixed_error ('No such record: ' . $c_type);
# TODO: should we check also other things? like Union or Glib::Boxed?
  }

  $self->_push_gir_record ($gir_record);
  $self->_push_c_class ($c_type);

  Common::Output::Generic::output ($self, $c_type, $cxx_type);
}

sub _get_temp_wrap_init_stack
{
  my ($self) = @_;

  return $self->{'temp_wrap_init_stack'};
}

sub push_temp_wrap_init
{
  my ($self, $repository, $get_type_func) = @_;
  my $level = $self->get_level ();
  my $c_includes = _get_c_includes ($repository);
  my $cxx_includes = [join ('', '"', $self->get_base (), '.h"'), join ('', '"private/', $self->get_base (), '_p.h"')];
  my $deprecated = 0;
  my $not_for_windows = 0;
  my $mm_module = $self->get_mm_module ();
  my $complete_cxx_class_type = Common::Output::Shared::get_complete_cxx_class_type ($self);
  my $complete_cxx_type = Common::Output::Shared::get_complete_cxx_type ($self);
  my $temp_wrap_init_stack = $self->_get_temp_wrap_init_stack ();

  push (@{$temp_wrap_init_stack},
        [
          $level,
          [],
          $c_includes,
          $cxx_includes,
          $deprecated,
          $not_for_windows,
          $mm_module,
          $get_type_func,
          $complete_cxx_class_type,
          $complete_cxx_type
        ]);
}

sub _on_class_g_object ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args > 2)
  {
    $self->fixed_warning ('Last ' . @args - 2 . ' parameters are deprecated.');
  }

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my $cxx_type = shift @args;
  my $c_type = shift @args;
  my $gir_class = $namespace->get_g_class_by_name ($c_type);

  unless (defined $gir_class)
  {
    $self->fixed_error ('No such class: ' . $c_type);
  }

  my $get_type_func = $gir_class->get_a_glib_get_type;

  unless (defined $get_type_func)
  {
    $self->fixed_error ('Class `' . $c_type . '\' has no get type function.');
  }

  my $gir_parent = $gir_class->get_a_parent;

  unless (defined $gir_parent)
  {
    $self->fixed_error ('Class `' . $c_type . '\' has no parent. (you are not wrapping GObject, are you?)');
  }

  my $gir_type_struct = $gir_class->get_a_glib_type_struct;

  unless (defined $gir_type_struct)
  {
    $self->fixed_error ('Class `' . $c_type . '\' has no Class struct.');
  }

  my @gir_prefixes = $namespace->get_a_c_identifier_prefixes;
  my $c_class_type = undef;

  foreach my $gir_prefix (@gir_prefixes)
  {
    my $temp_type = $gir_prefix . $gir_type_struct;

    if (defined $namespace->get_g_record_by_name ($temp_type))
    {
      $c_class_type = $temp_type;
      last;
    }
  }

  unless (defined $c_class_type)
  {
    $self->fixed_error ('Could not find any type struct (' . $gir_type_struct . ').');
  }

  my $c_parent_type = undef;
  my $c_parent_class_type = undef;

  # if parent is for example Gtk.Widget
  if ($gir_parent =~ /^([^.]+)\.(.*)/)
  {
    my $gir_parent_module = $1;
    my $gir_parent_type = $2;
    my $parent_repository = $repositories->get_repository ($gir_parent_module);

    unless (defined $parent_repository)
    {
      $self->fixed_error ('No such repository for parent: `' . $gir_parent_module . '\'.');
    }

    my $parent_namespace = $parent_repository->get_g_namespace_by_name ($gir_parent_module);

    unless (defined $parent_namespace)
    {
      $self->fixed_error ('No such namespace for parent: `' . $gir_parent_module . '\'.');
    }

    my @gir_parent_prefixes = split ',', $parent_namespace->get_a_c_identifier_prefixes;
    my $gir_parent_class = undef;

    foreach my $gir_parent_prefix (@gir_parent_prefixes)
    {
      my $temp_parent_type = $gir_parent_prefix . $gir_parent_type;

      $gir_parent_class = $parent_namespace->get_g_class_by_name ($temp_parent_type);

      if (defined $gir_parent_class)
      {
        $c_parent_type = $temp_parent_type;
        last;
      }
    }

    unless (defined $c_parent_type)
    {
      $self->fixed_error ('No such parent class in namespace: `' . $c_parent_type . '\.');
    }

    my $gir_parent_type_struct = $gir_parent_class->get_a_glib_type_struct;

    unless (defined $gir_parent_type_struct)
    {
      $self->fixed_error ('Parent of `' . $c_type . '\', `' . $c_parent_type . '\' has not Class struct.');
    }

    for my $gir_parent_prefix (@gir_parent_prefixes)
    {
      my $temp_parent_class_type = $gir_parent_prefix . $gir_parent_type_struct;
      my $gir_parent_class_struct = $parent_namespace->get_g_record_by_name ($temp_parent_class_type);

      if (defined $gir_parent_class_struct)
      {
        $c_parent_class_type = $temp_parent_class_type;
      }
    }

    unless (defined $c_parent_class_type)
    {
      $self->fixed_error ('Could not find type struct (' . $gir_parent_type_struct . ').');
    }
  }
  else
  {
    my $gir_parent_class = undef;

    foreach my $gir_prefix (@gir_prefixes)
    {
      my $temp_parent_type = $gir_prefix . $gir_parent;

      $gir_parent_class = $namespace->get_g_class_by_name ($temp_parent_type);

      if (defined $gir_parent_class)
      {
        $c_parent_type = $temp_parent_type;
        last;
      }
    }

    unless (defined $c_parent_type)
    {
      $self->fixed_error ('No such parent class in namespace: `' . $gir_parent . '\.');
    }

    my $gir_parent_type_struct = $gir_parent_class->get_a_glib_type_struct;

    unless (defined $gir_parent_type_struct)
    {
      $self->fixed_error ('Parent of `' . $c_type . '\', `' . $c_parent_type . '\' has not Class struct.');
    }

    for my $gir_prefix (@gir_prefixes)
    {
      my $temp_parent_class_type = $gir_prefix . $gir_parent_type_struct;
      my $gir_parent_class_struct = $namespace->get_g_record_by_name ($temp_parent_class_type);

      if (defined $gir_parent_class_struct)
      {
        $c_parent_class_type = $temp_parent_class_type;
      }
    }

    unless (defined $c_parent_class_type)
    {
      $self->fixed_error ('Could not find type struct (' . $gir_parent_type_struct . ').');
    }
  }

  my $type_info_local = $self->get_type_info_local;
# TODO: write an info about adding mapping when returned value
# TODO continued: is undefined.
  my $cxx_parent_type = $type_info_local->c_to_cxx ($c_parent_type);


  $self->_push_gir_class ($gir_class);
  $self->_push_c_class ($c_type);

  Common::Output::GObject::output $self,
                                  $c_type,
                                  $c_class_type,
                                  $c_parent_type,
                                  $c_parent_class_type,
                                  $get_type_func,
                                  $cxx_type,
                                  $cxx_parent_type;

  $self->push_temp_wrap_init ($repository, $get_type_func);
}

# TODO: set current gir_class.
sub _on_class_gtk_object ($)
{

}

sub _on_class_boxed_type ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args > 5)
  {
    $self->fixed_warning ('Last ' . @args - 5 . ' parameters are deprecated.');
  }

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my ($cxx_type, $c_type, $new_func, $copy_func, $free_func) = @args;
  my $gir_record = $namespace->get_g_record_by_name ($c_type);

  unless (defined $gir_record)
  {
    $self->fixed_error ('No such record: ' . $c_type);
  }

  my $get_type_func = $gir_record->get_a_glib_get_type;

  unless (defined $get_type_func)
  {
    $self->fixed_error ('Record `' . $c_type . '\' has no get type function.');
  }

# TODO: Check if we can support generating constructors with
# TODO continued: several parameters also.
  if (not defined $new_func or $new_func eq 'GUESS')
  {
    my $constructor_count = $gir_record->get_g_constructor_count;

    $new_func = undef;
    for (my $iter = 0; $iter < $constructor_count; ++$iter)
    {
      my $constructor = $gir_record->get_g_constructor_by_index ($iter);

      unless ($constructor->get_g_parameters_count)
      {
        $new_func = $constructor->get_a_c_identifier;
        last;
      }
    }
  }

  my @gir_prefixes = split ',', $namespace->get_a_c_symbol_prefixes;
  my $record_prefix = $gir_record->get_a_c_symbol_prefix;

  if (not defined $copy_func or $copy_func eq 'GUESS')
  {
    my $found_any = 0;

    $copy_func = undef;
    for my $prefix (@gir_prefixes)
    {
      for my $ctor_suffix ('copy', 'ref')
      {
        my $copy_ctor_name = join '_', $prefix, $record_prefix, $ctor_suffix;
        my $copy_ctor = $gir_record->get_g_method_by_name ($copy_ctor_name);

        if (defined $copy_ctor)
        {
          $found_any = 1;
          unless ($copy_ctor->get_g_parameters_count)
          {
            $copy_func = $copy_ctor_name;
          }
        }
      }
    }

    unless (defined $copy_func)
    {
      if ($found_any)
      {
        $self->fixed_error ('Found a copy/ref function, but its prototype was not the expected one. Please specify its name explicitly. Note that NONE is not allowed.');
      }
      else
      {
        $self->fixed_error ('Could not find any copy/ref function. Please specify its name explicitly. Note that NONE is not allowed.');
      }
    }
  }
  elsif ($copy_func ne 'NONE')
  {
    my $copy_ctor = $gir_record->get_g_method_by_name ($copy_func);

    unless (defined $copy_ctor)
    {
      $self->fixed_error ('Could not find such copy/ref function in Gir file: `' . $copy_func . '\'.');
    }
  }
  else
  {
    $self->fixed_error ('Copy/ref function can not be NONE.');
  }

  if (not defined $free_func or $free_func eq 'GUESS')
  {
    my $found_any = 0;

    $free_func = undef;
    for my $prefix (@gir_prefixes)
    {
      for my $dtor_suffix ('free', 'unref')
      {
        my $dtor_name = join '_', $prefix, $record_prefix, $dtor_suffix;
        my $dtor = $gir_record->get_g_method_by_name ($dtor_name);

        if (defined $dtor)
        {
          $found_any = 1;
          unless ($dtor->get_g_parameters_count)
          {
            $free_func = $dtor_name;
          }
        }
      }
    }

    unless (defined $free_func)
    {
      if ($found_any)
      {
        $self->fixed_error ('Found a free/unref function, but its prototype was not the expected one. Please specify its name explicitly. Note that NONE is not allowed.');
      }
      else
      {
        $self->fixed_error ('Could not find any free/unref function. Please specify its name explicitly. Note that NONE is not allowed.');
      }
    }
  }
  elsif ($free_func ne 'NONE')
  {
    my $dtor = $gir_record->get_g_method_by_name ($free_func);

    unless (defined $dtor)
    {
      $self->fixed_error ('Could not find such free/unref in Gir file: `' . $free_func . '\'.');
    }
  }
  else
  {
    $self->fixed_error ('Free/unref function can not be NONE.');
  }

  $self->_push_gir_record ($gir_record);
  $self->_push_c_class ($c_type);

  Common::Output::BoxedType::output $self,
                                    $c_type,
                                    $cxx_type,
                                    $get_type_func,
                                    $new_func,
                                    $copy_func,
                                    $free_func;
}

sub _on_class_boxed_type_static ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args > 2)
  {
    $self->fixed_warning ('Last ' . @args - 2 . ' parameters are useless.');
  }

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my ($cxx_type, $c_type) = @args;
  my $gir_record = $namespace->get_g_record_by_name ($c_type);

  unless (defined $gir_record)
  {
    $self->fixed_error ('No such record: ' . $c_type);
  }

  my $get_type_func = $gir_record->get_a_glib_get_type;

  unless (defined $get_type_func)
  {
    $self->fixed_error ('Record `' . $c_type . '\' has no get type function.');
  }

  $self->_push_gir_record ($gir_record);
  $self->_push_c_class ($c_type);

  Common::Output::BoxedTypeStatic::output $self,
                                          $c_type,
                                          $cxx_type,
                                          $get_type_func;
}

sub _on_class_interface ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args > 2)
  {
    $self->fixed_warning ('Last ' . @args - 2 . ' parameters are deprecated.');
  }

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my ($cxx_type, $c_type) = @args;
  my $gir_class = $namespace->get_g_class_by_name ($c_type);

  unless (defined $gir_class)
  {
    $self->fixed_error ('No such class: ' . $c_type);
  }

  my $get_type_func = $gir_class->get_a_glib_get_type;

  unless (defined $get_type_func)
  {
    $self->fixed_error ('Class `' . $c_type . '\' has no get type function.');
  }

  my $prerequisite_count = $gir_class->get_g_prerequisite_count;
  my $gir_parent = undef;

  for (my $iter = 0; $iter < $prerequisite_count; ++$iter)
  {
    my $prerequisite = $gir_class->get_g_prerequisite_by_index ($iter);

    if (defined $prerequisite)
    {
      my $prereq_name = $prerequisite->get_a_name;

      if ($prereq_name ne "GObject.Object")
      {
        $gir_parent = $prereq_name;
      }
    }
  }

  unless (defined $gir_parent)
  {
    $gir_parent = 'GObject.Object';
  }

  my $gir_type_struct = $gir_class->get_a_glib_type_struct;

  unless (defined $gir_type_struct)
  {
    $self->fixed_error ('Class `' . $c_type . '\' has no Iface struct.');
  }

  my @gir_prefixes = $namespace->get_a_c_identifier_prefixes;
  my $c_class_type = undef;

  foreach my $gir_prefix (@gir_prefixes)
  {
    my $temp_type = $gir_prefix . $gir_type_struct;

    if (defined $namespace->get_g_record_by_name ($temp_type))
    {
      $c_class_type = $temp_type;
      last;
    }
  }

  unless (defined $c_class_type)
  {
    $self->fixed_error ('Could not find any type struct (' . $gir_type_struct . ').');
  }

  my $c_parent_type = undef;

  # if parent is for example Gtk.Widget
  if ($gir_parent =~ /^([^.]+)\.(.*)/)
  {
    my $gir_parent_module = $1;
    my $gir_parent_type = $2;
    my $parent_repository = $repositories=>get_repository ($gir_parent_module);

    unless (defined $parent_repository)
    {
      $self->fixed_error ('No such repository for parent: `' . $gir_parent_module . '\'.');
    }

    my $parent_namespace = $parent_repository->get_g_namespace_by_name ($gir_parent_module);

    unless (defined $parent_namespace)
    {
      $self->fixed_error ('No such namespace for parent: `' . $gir_parent_module . '\'.');
    }

    my @gir_parent_prefixes = $parent_namespace->get_a_c_identifier_prefixes;

    foreach my $gir_parent_prefix (@gir_parent_prefixes)
    {
      my $temp_parent_type = $gir_parent_prefix . $gir_parent_type;
      my $gir_parent_class = $parent_namespace->get_g_class_by_name ($temp_parent_type);

      if (defined $gir_parent_class)
      {
        $c_parent_type = $temp_parent_type;
        last;
      }
    }

    unless (defined $c_parent_type)
    {
      $self->fixed_error ('No such parent class in namespace: `' . $c_parent_type . '\.');
    }
  }
  else
  {
    for my $gir_prefix (@gir_prefixes)
    {
      my $temp_parent_type = $gir_prefix . $gir_parent;
      my $gir_parent_class = $namespace->get_g_class_by_name ($temp_parent_type);

      if (defined $gir_parent_class)
      {
        $c_parent_type = $temp_parent_type;
        last;
      }
    }

    unless (defined $c_parent_type)
    {
      $self->fixed_error ('No such parent class in namespace: `' . $c_parent_type . '\.');
    }
  }

  my $type_info_local = $self->get_type_info_local;
  my $cxx_parent_type = $type_info_local->c_to_cxx ($c_parent_type);

  $self->_push_gir_class ($gir_class);
  $self->_push_c_class ($c_type);

  Common::Output::Interface::output $self,
                                    $c_type,
                                    $c_class_type,
                                    $c_parent_type,
                                    $cxx_type,
                                    $cxx_parent_type,
                                    $get_type_func;
  $self->push_temp_wrap_init ($repository, $get_type_func);
}

# TODO: some of the code here duplicates the code in next
# TODO continued: method.
sub _on_class_opaque_copyable ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args > 5)
  {
    $self->fixed_warning ('Last ' . @args - 2 . ' parameters are useless.');
  }

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my ($cxx_type, $c_type, $new_func, $copy_func, $free_func) = @args;
  my $gir_record = $namespace->get_g_record_by_name ($c_type);

  unless (defined $gir_record)
  {
    $self->fixed_error ('No such record: ' . $c_type);
  }

# TODO: Check if we can support generating constructors with
# TODO continued: several parameters also.
  if (not defined $new_func or $new_func eq 'GUESS')
  {
    my $constructor_count = $gir_record->get_g_constructor_count;

    $new_func = undef;
    for (my $iter = 0; $iter < $constructor_count; ++$iter)
    {
      my $constructor = $gir_record->get_g_constructor_by_index ($iter);

      unless ($constructor->get_g_parameters_count)
      {
        $new_func = $constructor->get_a_c_identifier;
        last;
      }
    }
  }

  my @gir_prefixes = split ',', $namespace->get_a_c_symbol_prefixes;
  my $record_prefix = $gir_record->get_a_c_symbol_prefix;

  if (not defined $copy_func or $copy_func eq 'GUESS')
  {
    my $found_any = 0;

    $copy_func = undef;
    for my $prefix (@gir_prefixes)
    {
      for my $ctor_suffix ('copy', 'ref')
      {
        my $copy_ctor_name = join '_', $prefix, $record_prefix, $ctor_suffix;
        my $copy_ctor = $gir_record->get_g_method_by_name ($copy_ctor_name);

        if (defined $copy_ctor)
        {
          $found_any = 1;
          unless ($copy_ctor->get_g_parameters_count)
          {
            $copy_func = $copy_ctor_name;
          }
        }
      }
    }

    unless (defined $copy_func)
    {
      if ($found_any)
      {
        $self->fixed_error ('Found a copy/ref function, but its prototype was not the expected one. Please specify its name explicitly. Note that NONE is not allowed.');
      }
      else
      {
        $self->fixed_error ('Could not find any copy/ref function. Please specify its name explicitly. Note that NONE is not allowed.');
      }
    }
  }
  elsif ($copy_func ne 'NONE')
  {
    my $copy_ctor = $gir_record->get_g_method_by_name ($copy_func);

    unless (defined $copy_ctor)
    {
      $self->fixed_error ('Could not find such copy/ref function in Gir file: `' . $copy_func . '\'.');
    }
  }
  else
  {
    $self->fixed_error ('Copy/ref function can not be NONE.');
  }

  if (not defined $free_func or $free_func eq 'GUESS')
  {
    my $found_any = 0;

    $free_func = undef;
    for my $prefix (@gir_prefixes)
    {
      for my $dtor_suffix ('free', 'unref')
      {
        my $dtor_name = join '_', $prefix, $record_prefix, $dtor_suffix;
        my $dtor = $gir_record->get_g_method_by_name ($dtor_name);

        if (defined $dtor)
        {
          $found_any = 1;
          unless ($dtor->get_g_parameters_count)
          {
            $free_func = $dtor_name;
          }
        }
      }
    }

    unless (defined $free_func)
    {
      if ($found_any)
      {
        $self->fixed_error ('Found a free/unref function, but its prototype was not the expected one. Please specify its name explicitly. Note that NONE is not allowed.');
      }
      else
      {
        $self->fixed_error ('Could not find any free/unref function. Please specify its name explicitly. Note that NONE is not allowed.');
      }
    }
  }
  elsif ($free_func ne 'NONE')
  {
    my $dtor = $gir_record->get_g_method_by_name ($free_func);

    unless (defined $dtor)
    {
      $self->fixed_error ('Could not find such free/unref in Gir file: `' . $free_func . '\'.');
    }
  }
  else
  {
    $self->fixed_error ('Free/unref function can not be NONE.');
  }

  $self->_push_gir_record ($gir_record);
  $self->_push_c_class ($c_type);

  Common::Output::OpaqueCopyable::output $self,
                                         $c_type,
                                         $cxx_type,
                                         $new_func,
                                         $copy_func,
                                         $free_func;
}

# TODO: some of the code below duplicates the code in method
# TODO continued: above.
sub _on_class_opaque_refcounted ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas $self->_extract_bracketed_text;

  if (@args > 5)
  {
    $self->fixed_warning ('Last ' . @args - 2 . ' parameters are useless.');
  }

  my $repositories = $self->get_repositories;
  my $module = $self->get_module;
  my $repository = $repositories->get_repository ($module);

  unless (defined $repository)
  {
    $self->fixed_error ('No such repository: ' . $module);
  }

  my $module_namespace = (split (/-/, $module))[0];
  my $namespace = $repository->get_g_namespace_by_name ($module_namespace);

  unless (defined $namespace)
  {
    $self->fixed_error ('No such namespace: ' . $module);
  }

  my ($cxx_type, $c_type, $new_func, $copy_func, $free_func) = @args;
  my $gir_record = $namespace->get_g_record_by_name ($c_type);

  unless (defined $gir_record)
  {
    $self->fixed_error ('No such record: ' . $c_type);
  }

# TODO: Check if we can support generating constructors with
# TODO continued: with several parameters also.
  if (not defined $new_func or $new_func eq 'GUESS')
  {
    my $constructor_count = $gir_record->get_g_constructor_count;

    $new_func = undef;
    for (my $iter = 0; $iter < $constructor_count; ++$iter)
    {
      my $constructor = $gir_record->get_g_constructor_by_index ($iter);

      unless ($constructor->get_g_parameters_count)
      {
        $new_func = $constructor->get_a_c_identifier;
        last;
      }
    }
  }

  my @gir_prefixes = split ',', $namespace->get_a_c_symbol_prefixes;
  my $record_prefix = $gir_record->get_a_c_symbol_prefix;

  if (not defined $copy_func or $copy_func eq 'GUESS')
  {
    my $found_any = 0;

    $copy_func = undef;
    for my $prefix (@gir_prefixes)
    {
      for my $ctor_suffix ('ref', 'copy')
      {
        my $copy_ctor_name = join '_', $prefix, $record_prefix, $ctor_suffix;
        my $copy_ctor = $gir_record->get_g_method_by_name ($copy_ctor_name);

        if (defined $copy_ctor)
        {
          $found_any = 1;
          unless ($copy_ctor->get_g_parameters_count)
          {
            $copy_func = $copy_ctor_name;
          }
        }
      }
    }

    unless (defined $copy_func)
    {
      if ($found_any)
      {
        $self->fixed_error ('Found a copy/ref function, but its prototype was not the expected one. Please specify its name explicitly. Note that NONE is not allowed.');
      }
      else
      {
        $self->fixed_error ('Could not find any copy/ref function. Please specify its name explicitly. Note that NONE is not allowed.');
      }
    }
  }
  elsif ($copy_func ne 'NONE')
  {
    my $copy_ctor = $gir_record->get_g_method_by_name ($copy_func);

    unless (defined $copy_ctor)
    {
      $self->fixed_error ('Could not find such copy/ref function in Gir file: `' . $copy_func . '\'.');
    }
  }
  else
  {
    $self->fixed_error ('Copy/ref function can not be NONE.');
  }

  if (not defined $free_func or $free_func eq 'GUESS')
  {
    my $found_any = 0;

    $free_func = undef;
    for my $prefix (@gir_prefixes)
    {
      for my $dtor_suffix ('unref', 'free')
      {
        my $dtor_name = join '_', $prefix, $record_prefix, $dtor_suffix;
        my $dtor = $gir_record->get_g_method_by_name ($dtor_name);

        if (defined $dtor)
        {
          $found_any = 1;
          unless ($dtor->get_g_parameters_count)
          {
            $free_func = $dtor_name;
          }
        }
      }
    }

    unless (defined $free_func)
    {
      if ($found_any)
      {
        $self->fixed_error ('Found a free/unref function, but its prototype was not the expected one. Please specify its name explicitly. Note that NONE is not allowed.');
      }
      else
      {
        $self->fixed_error ('Could not find any free/unref function. Please specify its name explicitly. Note that NONE is not allowed.');
      }
    }
  }
  elsif ($free_func ne 'NONE')
  {
    my $dtor = $gir_record->get_g_method_by_name ($free_func);

    unless (defined $dtor)
    {
      $self->fixed_error ('Could not find such free/unref in Gir file: `' . $free_func . '\'.');
    }
  }
  else
  {
    $self->fixed_error ('Free/unref function can not be NONE.');
  }

  $self->_push_gir_record ($gir_record);
  $self->_push_c_class ($c_type);

  Common::Output::OpaqueRefcounted::output $self,
                                           $c_type,
                                           $cxx_type,
                                           $new_func,
                                           $copy_func,
                                           $free_func;
}

sub _on_namespace_keyword ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;
  my $name = '';
  my $done = 0;
  my $in_s_comment = 0;
  my $in_m_comment = 0;

# TODO: why _extract_token is not used here?
  # we need to peek ahead to figure out what type of namespace
  # declaration this is.
  foreach my $token (@{$tokens})
  {
    if ($in_s_comment)
    {
      if ($token eq "\n")
      {
        $in_s_comment = 0;
      }
    }
    elsif ($in_m_comment)
    {
      if ($token eq '*/')
      {
        $in_m_comment = 0;
      }
    }
    elsif ($token eq '//')
    {
      $in_s_comment = 1;
    }
    elsif ($token eq '/*' or $token eq '/**')
    {
      $in_m_comment = 1;
    }
    elsif ($token eq '{')
    {
      my $level = $self->get_level;
      my $namespaces = $self->get_namespaces;
      my $namespace_levels = $self->get_namespace_levels;

      $name = Common::Util::string_trim ($name);
      push @{$namespaces}, $name;
      push @{$namespace_levels}, $level + 1;

      if (@{$namespaces} == 1)
      {
        $self->generate_first_namespace_number;

        my $section = Common::Output::Shared::get_section $self, Common::Sections::H_BEFORE_FIRST_NAMESPACE;

        $section_manager->append_section_to_section ($section, $main_section);
      }

      $done = 1;
    }
    elsif ($token eq ';')
    {
      $done = 1;
    }
    elsif ($token !~ /\s/)
    {
      if ($name ne '')
      {
        $self->fixed_error ('Unexpected `' . $token . '\' after namespace name.');
      }
      $name = $token;
    }

    if ($done)
    {
      $section_manager->append_string_to_section ('namespace', $main_section);
      return;
    }
  }
  $self->fixed_error ('Hit eof while processing `namespace\'.');
}

sub _on_insert_section ($)
{
  my ($self) = @_;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;
  my $str = Common::Util::string_trim $self->_extract_bracketed_text;

  $section_manager->append_section_to_section ($str, $main_section);
}

sub _on_class_keyword ($)
{
  my ($self) = @_;
  my $tokens = $self->get_tokens;
  my $section_manager = $self->get_section_manager;
  my $main_section = $self->get_main_section;
  my $name = '';
  my $done = 0;
  my $in_s_comment = 0;
  my $in_m_comment = 0;
  my $colon_met = 0;

  # we need to peek ahead to figure out what type of class
  # declaration this is.
  foreach my $token (@{$tokens})
  {
    next if (not defined $token or $token eq '');

    if ($in_s_comment)
    {
      if ($token eq "\n")
      {
        $in_s_comment = 0;
      }
    }
    elsif ($in_m_comment)
    {
      if ($token eq '*/')
      {
        $in_m_comment = 0;
      }
    }
    elsif ($token eq '//' or $token eq '///' or $token eq '//!')
    {
      $in_s_comment = 1;
    }
    elsif ($token eq '/*' or $token eq '/**' or $token eq '/*!')
    {
      $in_m_comment = 1;
    }
    elsif ($token eq '{')
    {
      my $level = $self->get_level;
      my $classes = $self->get_classes;
      my $class_levels = $self->get_class_levels;

      $name =~ s/\s+//g;
      push @{$classes}, $name;
      push @{$class_levels}, $level + 1;

      if (@{$classes} == 1)
      {
        $self->generate_first_class_number;

        my $section = Common::Output::Shared::get_section $self, Common::Sections::H_BEFORE_FIRST_CLASS;

        $section_manager->append_section_to_section ($section, $main_section);
      }

      $done = 1;
    }
    elsif ($token eq ';')
    {
      $done = 1;
    }
    elsif ($token eq ':')
    {
      $colon_met = 1;
    }
    elsif ($token !~ /\s/)
    {
      unless ($colon_met)
      {
        $name .= $token;
      }
    }

    if ($done)
    {
      $section_manager->append_string_to_section ('class', $main_section);
      return;
    }
  }
  $self->fixed_error ('Hit eof while processing `class\'.');
}

sub _on_module
{
  my ($self) = @_;
  my $str = Common::Util::string_trim $self->_extract_bracketed_text;

  $self->{'module'} = $str;
}

sub _on_ctor_default ($)
{
  my ($self) = @_;
  $self->_extract_bracketed_text;

# TODO: get default constructor from gir.
  Common::Output::Ctor::ctor_default $self;
}

sub _on_pinclude ($)
{
  my ($self) = @_;
  my $str = Common::Util::string_trim $self->_extract_bracketed_text;

  Common::Output::Misc::p_include $self, $str;
}

sub _on_push_named_conv ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args < 6)
  {
    $self->fixed_error ('Expected 6 parameters - conversion name, from type, to type, conversion for transfer none, conversion for transfer container and conversion for transfer full');
  }
  if (@args > 6)
  {
    $self->fixed_warning ('Superfluous parameter will be ignored.');
  }

  my $conv_name = shift (@args);
  my $type_info_local = $self->get_type_info_local ();

  if ($type_info_local->named_conversion_exists ($conv_name))
  {
    $self->fixed_error ('Conversion `' . $conv_name . '\' already exists.');
  }

  my ($from_type, $to_type, $transfer_none, $transfer_container, $transfer_full) = @args;
  my $any_conv_exists = 0;

  foreach my $transfer ($transfer_none, $transfer_container, $transfer_full)
  {
    if ($transfer eq 'NONE')
    {
      $transfer = undef;
    }
    else
    {
      $any_conv_exists = 1;
    }
  }

  unless ($any_conv_exists)
  {
    $self->fixed_error ('At least one conversion has to be not NONE.');
  }

  $type_info_local->push_named_conversion ($conv_name,
                                           Common::Shared::_type_fixup ($from_type),
                                           Common::Shared::_type_fixup ($to_type),
                                           $transfer_none,
                                           $transfer_container,
                                           $transfer_full);
}

sub _on_pop_named_conv ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args < 1)
  {
    $self->fixed_error ('Expected one parameter being name of conversion to be popped.');
  }
  if (@args > 1)
  {
    $self->fixed_warning ('Superfluous parameters will be ignored.');
  }

  my $conv_name = shift (@args);
  my $type_info_local = $self->get_type_info_local ();

  unless ($type_info_local->named_conversion_exists ($conv_name))
  {
    $self->fixed_error ('Conversion `' . $conv_name . '\' does not exist.');
  }

  $type_info_local->pop_named_conversion ($conv_name);
}

sub _on_add_conversion ($)
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args < 5)
  {
    $self->fixed_error ('Expected 5 parameters - from type, to type, conversion for transfer none, conversion for transfer container and conversion for transfer full');
  }
  if (@args > 5)
  {
    $self->fixed_warning ('Superfluous parameter will be ignored.');
  }

  my $conv_name = shift (@args);
  my $type_info_local = $self->get_type_info_local ();
  my ($from_type, $to_type, $transfer_none, $transfer_container, $transfer_full) = @args;
  my $any_conv_exists = 0;

  foreach my $transfer ($transfer_none, $transfer_container, $transfer_full)
  {
    if ($transfer eq 'NONE')
    {
      $transfer = undef;
    }
    else
    {
      $any_conv_exists = 1;
    }
  }

  unless ($any_conv_exists)
  {
    $self->fixed_error ('At least one conversion has to be not NONE.');
  }

  $type_info_local->add_conversion (Common::Shared::_type_fixup ($from_type),
                                    Common::Shared::_type_fixup ($to_type),
                                    $transfer_none,
                                    $transfer_container,
                                    $transfer_full);
}

# TODO: this should put some ifdefs around either class or file
sub _on_is_deprecated
{
  my ($self) = @_;
  my $temp_wrap_init_stack = $self->_get_temp_wrap_init_stack ();

  if (@{$temp_wrap_init_stack})
  {
    my $temp_wrap_init = $temp_wrap_init_stack->[-1];
    my $level = $self->get_level ();

    if ($temp_wrap_init->[0] == $level)
    {
      $temp_wrap_init->[TEMP_WRAP_INIT_DEPRECATED] = 1;
    }
  }
}

# TODO: move it elsewhere in the file.
sub _add_wrap_init_condition
{
  my ($self, $cpp_condition) = @_;
  my $temp_wrap_init_stack = $self->_get_temp_wrap_init_stack ();

  if (@{$temp_wrap_init_stack})
  {
    my $temp_wrap_init = $temp_wrap_init_stack->[-1];
    my $level = $self->get_level ();

    if ($temp_wrap_init->[0] == $level)
    {
      $temp_wrap_init->[TEMP_WRAP_INIT_CPP_CONDITION] = $cpp_condition;
    }
  }
}

sub _on_gtkmmproc_win32_no_wrap
{
  my ($self) = @_;

  $self->fixed_warning ('Deprecated. Use _GMMPROC_WRAP_CONDITIONALLY instead.');
  $self->_add_wrap_init_condition ('ifndef G_OS_WIN32');
}

sub _on_ascii_func
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 2)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  my $return_type = shift (@args);
  my $func_name = shift (@args);
  my $section_manager = $self->get_section_manager ();
  my @lines =
  (
    join ('', 'inline ', $return_type, ' ', $func_name, '(char c)'),
    join ('', '  { return g_ascii_', $func_name, '(c); }'),
    ''
  );
  my $main_section = $self->get_main_section ();

  $section_manager->append_string_to_section (join ("\n", @lines),
                                              $main_section);
}

sub _on_unichar_func
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 2)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  my $return_type = shift (@args);
  my $func_name = shift (@args);
  my $section_manager = $self->get_section_manager ();
  my @lines =
  (
    join ('', 'inline ', $return_type, ' ', $func_name, '(gunichar uc)'),
    join ('', '  { return g_unichar_', $func_name, '(uc); }'),
    ''
  );
  my $main_section = $self->get_main_section ();

  $section_manager->append_string_to_section (join ("\n", @lines),
                                              $main_section);
}

sub _on_unichar_func_bool
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 2)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  my $return_type = shift (@args);
  my $func_name = shift (@args);
  my $section_manager = $self->get_section_manager ();
  my @lines =
  (
    join ('', 'inline ', $return_type, ' ', $func_name, '(gunichar uc)'),
    join ('', '  { return (g_unichar_', $func_name, '(uc) != 0); }'),
    ''
  );
  my $main_section = $self->get_main_section ();

  $section_manager->append_string_to_section (join ("\n", @lines),
                                              $main_section);
}

# TODO: move it to Misc.pm
sub _on_config_include
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 1)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  my $include_file = shift (@args);
  my $section_manager = $self->get_section_manager ();
  my $section = Common::Output::Shared::get_section ($self, Common::Sections::H_BEGIN);
  my $code_string = Common::Output::Shared::nl (join ('', '#include <', $include_file, '>'));

  $section_manager->append_string_to_section ($code_string,
                                              $section);
}

# TODO: move it to Ctor.pm
sub _on_construct
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());
  my $section = $self->get_main_section ();
  my $section_manager = $self->get_section_manager ();
  my $params = '';

  if (@args)
  {
    my $param_str = join (', ', @args);

    $params = join ('', ', ', $param_str, ', static_cast<char*>(0)');
  }

  my @lines =
  (
    '// Mark this class as non-derived to allow C++ vfuncs to be skipped.',
    'Glib::ObjectBase(0),',
    join ('', 'CppParentType(Glib::ConstructParams(get_static_cpp_class_type_instance().init()', $params, ')')
  );

  $section_manager->append_string_to_section (join ("\n", @lines), $section);
}

sub _on_custom_default_ctor
{
  my ($self) = @_;
  my $variable = Common::Output::Shared::get_variable ($self, Common::Variables::CUSTOM_DEFAULT_CTOR);
  my $section_manager = $self->get_section_manager ();

  $section_manager->set_variable ($variable, 1);
}

sub _on_deprecate_ifdef_start
{
  my ($self) = @_;

  Common::Output::Shared::deprecate_start ($self);
}

sub _on_deprecate_ifdef_end
{
  my ($self) = @_;

  Common::Output::Shared::deprecate_end ($self);
}

sub _on_member_set
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 4)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  Common::Output::Member::output_set ($self, @args);
}

sub _on_member_set_ptr
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 4)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  Common::Output::Member::output_set_ptr ($self, @args);
}

sub _on_member_set_gobject
{
  my ($self) = @_;

  $self->fixed_warning ('This macro is deprecated, please use _MEMBER_SET_REF_PTR');
  $self->on_member_set_ref_ptr ();
}

sub _on_member_set_ref_ptr
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 4)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  Common::Output::Member::output_set_ref_ptr ($self, @args);
}

sub _on_member_get
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 4)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  Common::Output::Member::output_get ($self, @args);
}

sub _on_member_get_ptr
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 4)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  Common::Output::Member::output_get_ptr ($self, @args);
}

sub _on_member_get_gobject
{
  my ($self) = @_;

  $self->fixed_warning ('This macro is deprecated, please use _MEMBER_GET_REF_PTR');
  $self->_on_member_get_ref_ptr ();
}

sub _on_member_get_ref_ptr
{
  my ($self) = @_;
  my @args = Common::Shared::string_split_commas ($self->_extract_bracketed_text ());

  if (@args != 4)
  {
    $self->fixed_error ('Wrong number of parameters');
  }

  Common::Output::Member::output_get_ref_ptr ($self, @args);
}

sub _on_gmmproc_extra_namespace
{
  my ($self) = @_;

  $self->fixed_warning ('This macro is obsolete, just remove it.');
  $self->_extract_bracketed_text ();
}

sub _on_gmmproc_wrap_conditionally
{
  my ($self) = @_;
  my $cpp_condition = Common::Util::string_trim ($self->_extract_bracketed_text());

  if ($cpp_condition =~ /^#/)
  {
    $cpp_condition =~ s/^#//;
  }

  if ($cpp_condition !~ /^(?:(?:ifndef)|(?:ifdef)|(?:if))/)
  {
    $self->fixed_error ('Expected C preprocessor conditional (if, ifdef, ifndef))');
  }

  $self->_add_wrap_init_condition ($cpp_condition);
}

sub _on_include_in_wrap_init
{
  my ($self) = @_;
  my $temp_wrap_init_stack = $self->_get_temp_wrap_init_stack ();
  my $extra_include = Common::Util::string_trim ($self->_extract_bracketed_text());

  if (@{$temp_wrap_init_stack})
  {
    my $temp_wrap_init = $temp_wrap_init_stack->[-1];
    my $level = $self->get_level ();

    if ($temp_wrap_init->[0] == $level)
    {
      push (@{$temp_wrap_init->[TEMP_WRAP_INIT_EXTRA_INCLUDES]}, $extra_include);
    }
  }
}

sub _on_push_section
{
  my ($self) = @_;
  my $section_name = Common::Util::string_trim ($self->_extract_bracketed_text());
  my $traits = Common::Sections::get_section_traits_from_string ($section_name);

  if (defined ($traits))
  {
    my $full_section_name = Common::Output::Shared::get_section ($self, $traits);

    $self->_push_main_section ($full_section_name);
  }
  else
  {
    $self->fixed_error ('Unknown section: ' . $section_name);
  }
}

sub _on_pop_section
{
  my ($self) = @_;

  $self->_pop_main_section ();
}

sub _on_template_keyword
{
  my ($self) = @_;
  my $tokens = $self->get_tokens ();
  my $section_manager = $self->get_section_manager ();
  my $main_section = $self->get_main_section ();
  my $done = 0;
  my $in_s_comment = 0;
  my $in_m_comment = 0;
  my $template_level = 0;
  my @template_tokens = ('template');

  # extract all tokens with template angles (<...>), so we won't parse
  # class keyword in template context as in 'template<class T>'.
  while (@{$tokens})
  {
    my $token = $self->_extract_token ();

    if ($in_s_comment)
    {
      if ($token eq "\n")
      {
        $in_s_comment = 0;
      }
    }
    elsif ($in_m_comment)
    {
      if ($token eq '*/')
      {
        $in_m_comment = 0;
      }
    }
    elsif ($token eq '//' or $token eq '///' or $token eq '//!')
    {
      $in_s_comment = 1;
    }
    elsif ($token eq '/*' or $token eq '/**' or $token eq '/*!')
    {
      $in_m_comment = 1;
    }
    elsif ($token eq '<')
    {
      ++$template_level;;
    }
    elsif ($token eq '>')
    {
      unless ($template_level)
      {
        $self->fixed_error ('Expected \'<\' after template keyword, not \'>\'.');
      }
      --$template_level;
      unless ($template_level)
      {
        $done = 1;
      }
    }
    elsif ($token !~ /^\s+$/)
    {
      unless ($template_level)
      {
        $self->fixed_error ('Expected \'<\' after template keyword, not \'' . $token . '\'.');
      }
    }

    push (@template_tokens, $token);

    if ($done)
    {
      $section_manager->append_string_to_section (join ('', @template_tokens),
                                                  $main_section);
      return;
    }
  }
  $self->fixed_error ('Hit eof while processing `template\'.');
}

###
### HANDLERS ABOVE
###

sub get_stage_section_tuples ($)
{
  my ($self) = @_;

  return $self->{'stage_section_tuples'}
}

sub set_filename ($$)
{
  my ($self, $filename) = @_;

  $self->{'filename'} = $filename;
}

sub get_filename ($)
{
  my ($self) = @_;

  return $self->{'filename'};
}

sub get_base ($)
{
  my ($self) = @_;

  return $self->{'base'};
}

# TODO: private
sub _switch_to_stage ($$)
{
  my ($self, $stage) = @_;
  my $pairs = $self->get_stage_section_tuples;

  if (exists $pairs->{$stage})
  {
    my $tuple = $pairs->{$stage};
    my $main_section = $tuple->[0][0];
    my $tokens = $tuple->[1];
    my $ext = $tuple->[2];
    my $filename = join '.', $self->get_base, $ext;

    $self->set_parsing_stage ($stage);
    $self->set_main_section ($pairs->{$stage}[0][0]);
    $self->set_tokens ($self->{$pairs->{$stage}[1]});
    $self->set_filename ($filename);
  }
  else
  {
# TODO: internal error.
    die;
  }
}

sub get_repositories ($)
{
  my ($self) = @_;

  return $self->{'repositories'};
}

# public
sub new
{
  my ($type, $tokens_hg, $tokens_ccg, $type_info_global, $repositories, $mm_module, $base, $wrap_init_namespace) = @_;
  my $class = (ref $type or $type or 'Common::WrapParser');
  my $self =
  {
# TODO: check if all those fields are really needed.
    'line_num' => 1,
    'fixed_line_num' => 1,
    'level' => 0,
    'classes' => [],
    'class_levels' => [],
    'namespaces' => [],
    'namespace_levels' => [],
    'module' => '',
    'repositories' => $repositories,
    'tokens_hg' => [@{$tokens_hg}],
    'tokens_ccg' => [@{$tokens_ccg}],
    'tokens_null' => [],
    'tokens' => [],
    'parsing_stage' => STAGE_INVALID,
    'main_sections_stack' => [Common::Sections::DEV_NULL->[0]],
    'section_manager' => Common::SectionManager->new ($base, $mm_module),
    'stage_section_tuples' =>
    {
      STAGE_HG() => [Common::Sections::H_CONTENTS, 'tokens_hg', 'hg'],
      STAGE_CCG() => [Common::Sections::CC_CONTENTS, 'tokens_ccg', 'ccg'],
      STAGE_INVALID() => [Common::Sections::DEV_NULL, 'tokens_null', 'BAD']
    },
    'type_info_local' => Common::TypeInfo::Local->new ($type_info_global),
    'counter' => 0,
    'gir_stack' => [],
    'c_stack' => [],
    'mm_module' => $mm_module,
    'base' => $base,
    'filename' => undef,
    'wrap_init_entries' => [],
    'temp_wrap_init_stack' => [],
    'wrap_init_namespace' => $wrap_init_namespace
  };

  $self = bless $self, $class;
  $self->{'handlers'} =
  {
# TODO: change those to 'sub { $self->method; }'
    '{' => sub { $self->_on_open_brace (@_); },
    '}' => sub { $self->_on_close_brace (@_); },
#    '`' => sub { $self->_on_backtick (@_); }, # probably won't be needed anymore
#    '\'' => sub { $self->_on_apostrophe (@_); }, # probably won't be needed anymore
    '"' => sub { $self->_on_string_literal (@_); },
    '//' => sub { $self->_on_comment_cxx (@_); },
    '///' => sub { $self->_on_comment_doxygen_single (@_); },
    '//!' => sub { $self->_on_comment_doxygen_single (@_); },
    '/*' => sub { $self->_on_comment_c (@_); },
    '/**' => sub { $self->_on_comment_doxygen (@_); },
    '/*!' => sub { $self->_on_comment_doxygen (@_); },
    '#m4begin' => sub { $self->_on_m4_section (@_); }, # probably won't be needed anymore
    '#m4' => sub { $self->_on_m4_line (@_); }, # probably won't be needed anymore
    '_DEFS' => sub { $self->_on_defs (@_); }, # probably won't be needed anymore
    '_IGNORE' => sub { $self->_on_ignore (@_); },
    '_IGNORE_SIGNAL' => sub { $self->_on_ignore_signal (@_); },
    '_WRAP_METHOD' => sub { $self->_on_wrap_method (@_); },
    '_WRAP_METHOD_DOCS_ONLY' => sub { $self->_on_wrap_method_docs_only (@_); },
#    '_WRAP_CORBA_METHOD'=> sub { $self->_on_wrap_corba_method (@_); },
    '_WRAP_SIGNAL' => sub { $self->_on_wrap_signal (@_); },
    '_WRAP_PROPERTY' => sub { $self->_on_wrap_property (@_); },
    '_WRAP_VFUNC' => sub { $self->_on_wrap_vfunc (@_); },
    '_WRAP_CTOR' => sub { $self->_on_wrap_ctor (@_); },
    '_WRAP_CREATE' => sub { $self->_on_wrap_create (@_); },
    '_WRAP_ENUM' => sub { $self->_on_wrap_enum (@_); },
    '_WRAP_GERROR' => sub { $self->_on_wrap_gerror (@_); },
    '_IMPLEMENTS_INTERFACE' => sub { $self->_on_implements_interface (@_); },
    '_CLASS_GENERIC' => sub { $self->_on_class_generic (@_); },
    '_CLASS_GOBJECT' => sub { $self->_on_class_g_object (@_); },
    '_CLASS_GTKOBJECT' => sub { $self->_on_class_gtk_object (@_); },
    '_CLASS_BOXEDTYPE' => sub { $self->_on_class_boxed_type (@_); },
    '_CLASS_BOXEDTYPE_STATIC' => sub { $self->_on_class_boxed_type_static (@_); },
    '_CLASS_INTERFACE' => sub { $self->_on_class_interface (@_); },
    '_CLASS_OPAQUE_COPYABLE' => sub { $self->_on_class_opaque_copyable (@_); },
    '_CLASS_OPAQUE_REFCOUNTED' => sub { $self->_on_class_opaque_refcounted (@_); },
    'namespace' => sub { $self->_on_namespace_keyword (@_); },
    '_INSERT_SECTION' => sub { $self->_on_insert_section (@_); },
    'class' => sub { $self->_on_class_keyword (@_); },
    '_MODULE' => sub { $self->_on_module (@_); },
    '_CTOR_DEFAULT' => sub { $self->_on_ctor_default (@_); },
    '_PINCLUDE' => sub { $self->_on_pinclude (@_); },
    '_PUSH_NAMED_CONV' => sub { $self->_on_push_named_conv (@_); },
    '_POP_NAMED_CONV' => sub { $self->_on_pop_named_conv (@_); },
    '_ADD_CONVERSION' => sub { $self->_on_add_conversion (@_); },
    '_IS_DEPRECATED' => sub { $self->_on_is_deprecated (@_); },
    '_GTKMMPROC_WIN32_NO_WRAP' => sub { $self->_on_gtkmmproc_win32_no_wrap (@_); },
# TODO: this should be an example of plugin handler.
    '_ASCII_FUNC' => sub { $self->_on_ascii_func (@_); },
# TODO: this should be an example of plugin handler.
    '_UNICHAR_FUNC' => sub { $self->_on_unichar_func (@_); },
# TODO: this should be an example of plugin handler.
    '_UNICHAR_FUNC_BOOL' => sub { $self->_on_unichar_func_bool (@_); },
    '_CONFIGINCLUDE' => sub { $self->_on_config_include (@_); },
    '_CONSTRUCT' => sub { $self->_on_construct (@_); },
    '_CUSTOM_DEFAULT_CTOR' => sub { $self->_on_custom_default_ctor (@_); },
    '_DEPRECATE_IFDEF_START' => sub { $self->_on_deprecate_ifdef_start (@_); },
    '_DEPRECATE_IFDEF_END' => sub { $self->_on_deprecate_ifdef_end (@_); },
    '_MEMBER_SET' => sub { $self->_on_member_set (@_); },
    '_MEMBER_SET_PTR' => sub { $self->_on_member_set_ptr (@_); },
    '_MEMBER_SET_GOBJECT' => sub { $self->_on_member_set_gobject (@_); },
    '_MEMBER_SET_REF_PTR' => sub { $self->_on_member_set_ref_ptr (@_); },
    '_MEMBER_GET' => sub { $self->_on_member_get (@_); },
    '_MEMBER_GET_PTR' => sub { $self->_on_member_get_ptr (@_); },
    '_MEMBER_GET_GOBJECT' => sub { $self->_on_member_get_gobject (@_); },
    '_MEMBER_GET_REF_PTR' => sub { $self->_on_member_get_ref_ptr (@_); },
    '_GMMPROC_EXTRA_NAMESPACE' => sub { $self->_on_gmmproc_extra_namespace (@_); },
    '_GMMPROC_WRAP_CONDITIONALLY' => sub { $self->_on_gmmproc_wrap_conditionally (@_); },
    '_INCLUDE_IN_WRAP_INIT' => sub { $self->_on_include_in_wrap_init (@_); },
    '_PUSH_SECTION' => sub { $self->_on_push_section (@_); },
    '_POP_SECTION' => sub { $self->_on_pop_section (@_); },
    'template' => sub { $self->_on_template_keyword (@_); }
  };

  return $self;
}

sub get_wrap_init_namespace
{
  my ($self) = @_;

  return $self->{'wrap_init_namespace'};
}

sub get_wrap_init_entries
{
  my ($self) = @_;

  return $self->{'wrap_init_entries'};
}

sub get_type_info_local ($)
{
  my ($self) = @_;

  return $self->{'type_info_local'};
}

sub get_number ($)
{
  my ($self) = @_;
  my $c = 'counter';
  my $number = $self->{$c};

  ++$self->{$c};
  return $number;
}

sub generate_first_class_number ($)
{
  my ($self) = @_;

  $self->{'first_class_number'} = $self->get_number;
}

sub get_first_class_number ($)
{
  my ($self) = @_;

  return $self->{'first_class_number'};
}

sub generate_first_namespace_number ($)
{
  my ($self) = @_;

  $self->{'first_namespace_number'} = $self->get_number;
}

sub get_first_namespace_number ($)
{
  my ($self) = @_;

  $self->{'first_namespace_number'};
}

# public
sub get_namespaces ($)
{
  my ($self) = @_;

  return $self->{'namespaces'};
}

sub get_namespace_levels ($)
{
  my ($self) = @_;

  return $self->{'namespace_levels'};
}

sub get_classes ($)
{
  my ($self) = @_;

  return $self->{'classes'};
}

sub get_class_levels ($)
{
  my ($self) = @_;

  return $self->{'class_levels'};
}

# public
sub get_section_manager ($)
{
  my ($self) = @_;

  return $self->{'section_manager'};
}

sub _get_main_sections_stack
{
  my ($self) = @_;

  return $self->{'main_sections_stack'};
}

# public
sub get_main_section ($)
{
  my ($self) = @_;
  my $main_sections_stack = $self->_get_main_sections_stack ();

  if (@{$main_sections_stack})
  {
    return $main_sections_stack->[-1];
  }
  return Common::Sections::DEV_NULL->[0];
}

sub set_main_section ($$)
{
  my ($self, $main_section) = @_;

  $self->{'main_sections_stack'} = [$main_section];
}

sub _push_main_section
{
  my ($self, $main_section) = @_;
  my $main_sections_stack = $self->_get_main_sections_stack ();

  push (@{$main_sections_stack}, $main_section);
}

sub _pop_main_section
{
  my ($self) = @_;
  my $main_sections_stack = $self->_get_main_sections_stack ();

  if (@{$main_sections_stack})
  {
    pop (@{$main_sections_stack});
  }
}

sub set_parsing_stage ($$)
{
  my ($self, $parsing_stage) = @_;

  $self->{'parsing_stage'} = $parsing_stage;
}

sub set_tokens ($$)
{
  my ($self, $tokens) = @_;

  $self->{'tokens'} = $tokens;
}

sub get_tokens ($)
{
  my ($self) = @_;

  return $self->{'tokens'};
}

sub get_line_num ($)
{
  my ($self) = @_;

  return $self->{'line_num'};
}

sub inc_line_num ($$)
{
  my ($self, $inc) = @_;

  $self->{'line_num'} += $inc;
}

sub _set_fixed_line_num ($)
{
  my ($self) = @_;

  $self->{'fixed_line_num'} = $self->get_line_num;
}

sub _get_fixed_line_num ($)
{
  my ($self) = @_;

  return $self->{'fixed_line_num'};
}

sub get_current_macro ($)
{
  my ($self) = @_;

  return $self->{'current_macro'};
}

sub _set_current_macro ($$)
{
  my ($self, $macro) = @_;

  $self->{'current_macro'} = $macro;
}

sub get_level ($)
{
  my ($self) = @_;

  return $self->{'level'};
}

sub dec_level ($)
{
  my ($self) = @_;

  --$self->{'level'};
}

sub inc_level ($)
{
  my ($self) = @_;

  ++$self->{'level'};
}

sub get_module ($)
{
  my ($self) = @_;

  return $self->{'module'};
}

sub get_mm_module ($)
{
  my ($self) = @_;

  return $self->{'mm_module'};
}

sub parse ($)
{
  my ($self) = @_;
  my $handlers = $self->{'handlers'};
  my $section_manager = $self->get_section_manager;
  my @stages = (STAGE_HG, STAGE_CCG);

  for my $stage (@stages)
  {
    $self->_switch_to_stage ($stage);

    my $tokens = $self->get_tokens;

    while (@{$tokens})
    {
      my $token = $self->_extract_token;

      if (exists $handlers->{$token})
      {
        my $handler = $handlers->{$token};

        $self->_set_current_macro ($token);
        $self->_set_fixed_line_num;

        # handler call
        &{$handler} ();
      }
      else
      {
        my $main_section = $self->get_main_section;
        # no handler found - just paste the token to main section
        $section_manager->append_string_to_section ($token, $main_section);
# TODO: remove it later.
        if ($token =~ /^[A-Z_]{2,}$/)
        {
          print STDERR $token . ": Possible not implemented token!\n";
        }
      }
    }
  }
}

# TODO: warning and error functions should not print messages
# TODO continued: immediately - they should just put messages
# TODO continued: into an array and that would be printed by
# TODO continued: Gmmproc.

sub _print_with_loc ($$$$$)
{
  my ($self, $line_num, $type, $message, $fatal) = @_;
  my $full_message = join '', (join ':', $self->{'filename'}, $self->get_current_macro, $line_num, $type, $message), "\n";

  print STDERR $full_message;

  if ($fatal)
  {
# TODO: throw an exception or something.
    exit 1;
  }
}

sub error_with_loc ($$$)
{
  my ($self, $line_num, $message) = @_;
  my $type = 'ERROR';
  my $fatal = 1;

  $self->_print_with_loc ($line_num, $type, $message, $fatal);
}

sub error ($$)
{
  my ($self, $message) = @_;

  $self->error_with_loc ($self->get_line_num, $message);
}

sub fixed_error ($$)
{
  my ($self, $message) = @_;
  my $line_num = $self->_get_fixed_line_num;

  $self->error_with_loc ($line_num, $message);
}

sub fixed_error_non_fatal ($$)
{
  my ($self, $message) = @_;
  my $line_num = $self->_get_fixed_line_num;
  my $type = 'ERROR';
  my $fatal = 0;

  $self->_print_with_loc ($line_num, $type, $message, $fatal);
}

sub warning_with_loc ($$$)
{
  my ($self, $line_num, $message) = @_;
  my $type = 'WARNING';
  my $fatal = 0;

  $self->_print_with_loc ($line_num, $type, $message, $fatal);
}

sub warning ($$)
{
  my ($self, $message) = @_;

  $self->warning_with_loc ($self->get_line_num, $message);
}

sub fixed_warning ($$)
{
  my ($self, $message) = @_;
  my $line_num = $self->_get_fixed_line_num;

  $self->warning_with_loc ($line_num, $message);
}

1; # indicate proper module load.
