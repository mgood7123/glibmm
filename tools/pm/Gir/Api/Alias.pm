## This file was generated by taghandlerwriter.pl script.
##
## Copyright 2011 Krzesimir Nowak
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the Free Software
## Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
##

package Gir::Api::Alias;

use strict;
use warnings;

use parent qw(Gir::Api::Common::Base);

use Gir::Api::Attribute;
use Gir::Api::Doc;
use Gir::Api::Type;

sub new ($)
{
  my $type = shift;
  my $class = (ref ($type) or $type or 'Gir::Api::Alias');
  my $groups =
  [
    'group_attribute',
    'group_doc',
    'group_type'
  ];
  my $attributes =
  [
    'attribute_c_type',
    'attribute_deprecated',
    'attribute_deprecated_version',
    'attribute_introspectable',
    'attribute_name'
  ];
  my $self = $class->SUPER::new ($groups, $attributes);

  bless ($self, $class);
  return $self;
}

sub new_with_params ($$)
{
  my ($type, $params) = @_;
  my $self = Gir::Api::Alias::new ($type);

  $self->set_a_c_type($params->{'c:type'});
  $self->set_a_deprecated($params->{'deprecated'});
  $self->set_a_deprecated_version($params->{'deprecated-version'});
  $self->set_a_introspectable($params->{'introspectable'});
  $self->set_a_name($params->{'name'});

  return $self;
}

sub get_g_attribute_by_name ($$)
{
  my ($self, $name) = @_;

  return $self->_get_group_member_by_name ('group_attribute', $name);
}

sub get_g_doc_by_name ($$)
{
  my ($self, $name) = @_;

  return $self->_get_group_member_by_name ('group_doc', $name);
}

sub get_g_type_by_name ($$)
{
  my ($self, $name) = @_;

  return $self->_get_group_member_by_name ('group_type', $name);
}


sub get_g_attribute_by_index ($$)
{
  my ($self, $index) = @_;

  return $self->_get_group_member_by_index ('group_attribute', $index);
}

sub get_g_doc_by_index ($$)
{
  my ($self, $index) = @_;

  return $self->_get_group_member_by_index ('group_doc', $index);
}

sub get_g_type_by_index ($$)
{
  my ($self, $index) = @_;

  return $self->_get_group_member_by_index ('group_type', $index);
}


sub get_g_attribute_count ($)
{
  my $self = shift;

  return $self->_get_group_member_count ('group_attribute');
}

sub get_g_doc_count ($)
{
  my $self = shift;

  return $self->_get_group_member_count ('group_doc');
}

sub get_g_type_count ($)
{
  my $self = shift;

  return $self->_get_group_member_count ('group_type');
}


sub add_g_attribute ($$$)
{
  my ($self, $member_name, $member) = @_;

  $self->_add_member_to_group ('group_attribute', $member_name, $member);
}

sub add_g_doc ($$$)
{
  my ($self, $member_name, $member) = @_;

  $self->_add_member_to_group ('group_doc', $member_name, $member);
}

sub add_g_type ($$$)
{
  my ($self, $member_name, $member) = @_;

  $self->_add_member_to_group ('group_type', $member_name, $member);
}


sub get_a_c_type ($)
{
  my ($self) = @_;

  return $self->_get_attribute ('attribute_c_type');
}

sub get_a_deprecated ($)
{
  my ($self) = @_;

  return $self->_get_attribute ('attribute_deprecated');
}

sub get_a_deprecated_version ($)
{
  my ($self) = @_;

  return $self->_get_attribute ('attribute_deprecated_version');
}

sub get_a_introspectable ($)
{
  my ($self) = @_;

  return $self->_get_attribute ('attribute_introspectable');
}

sub get_a_name ($)
{
  my ($self) = @_;

  return $self->_get_attribute ('attribute_name');
}


sub set_a_c_type ($$)
{
  my ($self, $value) = @_;

  $self->_set_attribute ('attribute_c_type', $value);
}

sub set_a_deprecated ($$)
{
  my ($self, $value) = @_;

  $self->_set_attribute ('attribute_deprecated', $value);
}

sub set_a_deprecated_version ($$)
{
  my ($self, $value) = @_;

  $self->_set_attribute ('attribute_deprecated_version', $value);
}

sub set_a_introspectable ($$)
{
  my ($self, $value) = @_;

  $self->_set_attribute ('attribute_introspectable', $value);
}

sub set_a_name ($$)
{
  my ($self, $value) = @_;

  $self->_set_attribute ('attribute_name', $value);
}


1; # indicate proper module load.