# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# XmlPlugin is Copyright (C) 2025-2026 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::XmlPlugin::Core;

=begin TML

---+ package Foswiki::Plugins::XmlPlugin::Core

core class for this plugin

an singleton instance is allocated on demand

=cut

use strict;
use warnings;


use Foswiki ();
use Foswiki::Func ();
use XML::LibXML;
use XML::LibXSLT;
use Encode ();
use Error qw(:try);

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0; # toggle me

BEGIN {
  XML::LibXSLT->register_function("urn:foswiki", "entityEncode", sub { 
    return join("", map {Foswiki::entityEncode($_)} @_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "entityDecode", sub { 
    return join("", map {Foswiki::entityDecode($_)} @_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "urlEncode", sub { 
    return join("", map {Foswiki::urlEncode($_)} @_) // '';
  });

  XML::LibXSLT->register_function("urn:foswiki", "urlDecode", sub { 
    return join("", map {Foswiki::urlDecode($_)} @_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "isTrue", sub { 
    return Foswiki::Func::isTrue(shift);
  });

  XML::LibXSLT->register_function("urn:foswiki", "getScriptUrl", sub { 
    return Foswiki::Func::getScriptUrl (@_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "getScriptUrlPath", sub { 
    return Foswiki::Func::getScriptUrlPath(@_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "getPubUrlPath", sub { 
    return Foswiki::Func::getPubUrlPath(@_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "inContext", sub { 
    my $id = shift // '';
    return exists(Foswiki::Func::getContext()->{$id}) ? 1 : 0;
  });

  XML::LibXSLT->register_function("urn:foswiki", "getPreferencesValue", sub { 
    return Foswiki::Func::getPreferencesValue(@_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "getPreferencesFlag", sub { 
    return Foswiki::Func::getPreferencesFlag(@_);
  });

  XML::LibXSLT->register_function("urn:foswiki", "extract", sub { 
    my ($text, $pattern) = @_;

    $text = quotemeta($text // "");
    $pattern //= "";

    return safeEval("'$text' =~ /$pattern/; return \$1;") 
  });

  XML::LibXSLT->register_function("urn:foswiki", "subst", sub { 
    my ($text, $pattern, $with, $flags) = @_;

    $flags //= "";
    $text = quotemeta($text // "");
    $pattern //= "";
    $with //= "";

    return safeEval("my \$res = '$text'; \$res =~ s/$pattern/$with/$flags; return \$res;") 
  });
}

=begin TML

---++ ObjectMethod safeEval() 

safe eval using a secured compartment

=cut

my $safeCpt;
sub safeEval {
  my $text = shift;

  unless (defined $safeCpt) {
    $safeCpt = Safe->new();
    $safeCpt->deny(":subprocess");
  }

  my $res = $safeCpt->reval($text, 1);
  #print STDERR "called safeEval($text) = ".($res//'undef')."\n";

  return $res;
}


=begin TML

---++ ClassMethod new() -> $core

constructor for a Core object

=cut

sub new {
  my $class = shift;
  my $session = shift;

  my $this = bless({
    session => $session,
    @_
  }, $class);

  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when destroying this object

=cut

sub finish {
  my $this = shift;

  undef $this->{session};
  undef $this->{security};
  undef $safeCpt;

  foreach my $key (keys %{$this->{xmls}}) {
    undef $this->{xmls}{$key};
  }

  undef $this->{xmls};
}

=begin TML

---++ ObjectMethod XML($params, $topic, $web) -> $string

implements the =%XML= macro

=cut

sub XML {
  my ($this, $params, $topic, $web) = @_;

  _writeDebug("called XML(web=$web, topic=$topic, params=$params)");
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($params->{web} // $web, $params->{topic} // $topic);
  return _inlineError("topic not found") unless Foswiki::Func::topicExists($web, $topic);

  my $xmlAttachment = $params->{_DEFAULT} // $params->{attachment};
  return _inlineError("no attachment specified") unless $xmlAttachment;
  return _inlineError("attachment not found") unless Foswiki::Func::attachmentExists($web, $topic, $xmlAttachment);

  my $result = "";
  my $error = "";

  try {
  
    my $doc = $this->getXmlFromAttachment($web, $topic, $xmlAttachment);
    my $isRaw = Foswiki::Func::isTrue($params->{raw}, 0);
    my $xpath = $params->{xpath} // "";
    my $xslt = $params->{xslt} // "";
    my $xsltAttachment = $params->{xslt_attachment} // '';

    # raw 
    if ($isRaw) {
      $result = "<verbatim>$doc</verbatim>";
    }

    # xslt mode
    elsif ($xslt || $xsltAttachment) {
      my $style;

      # inline
      if ($xslt) {
        $style = $this->getStyleFromString($xslt);
      } 

      # attachment
      else {
        my ($xsltWeb, $xsltTopic) = Foswiki::Func::normalizeWebTopicName($params->{xslt_web} // $web, $params->{xslt_topic} // $topic);
        throw Error::Simple("xslt not found") unless Foswiki::Func::topicExists($xsltWeb, $xsltTopic);
        $style = $this->getStyleFromAttachment($xsltWeb, $xsltTopic, $xsltAttachment);
      }

      throw Error::Simple("cannot parse stylesheet")
        unless $style;

      my %vars = ();
      while (my ($key,$val) = each %$params) {
        next if $key =~ /^(_DEFAULT|_RAW|attachment|xslt|xslt_attachment|xslt_web|xslt_topic|web|topic|xpath|raw)$/;
        $vars{$key} = $val;
      }
      
      my $res = $style->transform($doc, XML::LibXSLT::xpath_to_string(%vars));
      $result = $style->output_as_bytes($res);
      $result = Encode::decode_utf8($result);
    }

    # xpath mode
    elsif ($xpath) {
    
      my @results = ();
      my $index = 0;
      my $skip = $params->{skip};
      my $limit = $params->{limit};
      foreach my $node ($doc->findnodes($xpath)) {
        $index++;
        next if $skip && $index < $skip;

        my $line = $params->{format};
        if (defined $line) {
          $line =~ s/\$index\b/$index/g;
          $line =~ s/\$nodeName\b/$node->nodeName()/ge;
          $line =~ s/\$nodeValue\b/$node->nodeValue()/ge;
          $line =~ s/\$nodeType\b/$node->nodeType()/ge;
          $line =~ s/\$textContent\b/$node->textContent()/ge;
          $line =~ s/\$findValue\((.*?)\)/$node->findvalue($1)/ge;
          $line =~ s/\$find\((.*?)\)/join(", ", map {$_->to_literal()} $node->find($1))/ge;
          $line =~ s/\$encode\((.*)\)/_entityEncode($1)/ge;
        } else {
          $line =  $node->to_literal();
        }

        push @results, $line;

        last if $limit && scalar(@results) >= $limit;
      }

      my $header = $params->{header} // '';
      my $separator = $params->{separator} // '';
      my $footer = $params->{separator} // '';

      $result = $header . join($separator, @results) . $footer;
      $result =~ s/\$total\b/$index/g;
    }
  } catch Error with {
    $error = shift;
  };

  return _inlineError($error) if $error;

  return Foswiki::Func::decodeFormatTokens($result);
}

=begin TML

---++ ObjectMethod getXmlFromAttachment($web, $topic, $attachment) -> $doc

returns an XML::LibXML::Document object by reading the give attachment at the web.topic
address. throws an exception if anything goes wrong.

=cut

sub getXmlFromAttachment {
  my ($this, $web, $topic, $attachment) = @_;

  my $wikiName = Foswiki::Func::getWikiName();
  throw Error::Simple("access denied") unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, $topic, $web);

  $web =~ s/\./\//g;
  my $file = $Foswiki::cfg{PubDir} . "/" . $web . "/" . $topic . "/" . $attachment;
  throw Error::Simple("attachment $attachment not found at $web.$topic") unless -e $file;

  my $doc = $this->{xmls}{$file};
  return $doc if defined $doc;

  $doc = $this->{xmls}{$file} = eval {
    XML::LibXML->load_xml(location => $file, no_cdata => 1);
  };

  throw Error::Simple($@) if $@;

  return $doc;
}

=begin TML

---++ ObjectMethod getStyleFromAttachment($web, $topic, $attachment) -> $stylesheet

returns an XML::LibXSLT::Stylesheet by reading the given attachment from web.topic.
throws an exception if anything goes wrong.

=cut

sub getStyleFromAttachment {
  my ($this, $web, $topic, $attachment) = @_;

  my $doc = $this->getXmlFromAttachment($web, $topic, $attachment);
  throw Error::Simple("cannot style") unless $doc;

  my $xslt = XML::LibXSLT->new();
  $xslt->security_callbacks($this->security);

  return $xslt->parse_stylesheet($doc);
}

=begin TML

---++ ObjectMethod getXmlFromString($string) -> $doc

returns an XML::LibXML::Document object by parsing the given string

=cut

sub getXmlFromString {
  my ($this, $string) = @_;

  return XML::LibXML->load_xml(string => $string);
}

=begin TML

---++ ObjectMethod getStyleFromString($string) -> $stylesheet

returns an XML::LibXML::Stylesheet by parsing the given string

=cut

sub getStyleFromString {
  my ($this, $string) = @_;

  my $doc = $this->getXmlFromString($string);
  my $xslt = XML::LibXSLT->new();
  $xslt->security_callbacks($this->security);

  return $xslt->parse_stylesheet($doc);
}

=begin TML

---++ ObjectMethod security() -> $security

returns an XML::LibXSLT::Security object to be plugged into a stylesheet.
note that any read/write interation with files or urls are prohibited that way.

=cut

sub security {
  my $this = shift;

  my $security = $this->{security};
  return $security if $security;

  $security = $this->{security} = XML::LibXSLT::Security->new();

  # disable all
  $security->register_callback( read_file  => sub { return 0; } );
  $security->register_callback( write_file => sub { return 0; } );
  $security->register_callback( create_dir => sub { return 0; } );
  $security->register_callback( read_net   => sub { return 0; } );
  $security->register_callback( write_net  => sub { return 0; } );

  return $security;
}

# statics

sub _inlineError {
  my $msg = shift;

  print STDERR "ERROR: $msg\n";
  $msg =~ s/ at \/.*$//;
  $msg =~ s/^\/.* (parser error)/$1/;
  $msg =~ s/file \/(.*?) //g;
  return "<span class='foswikiAlert'>$msg</span>";
}

sub _writeDebug {
  return unless TRACE;
  #Foswiki::Func::writeDebug("XmlPlugin::Core - $_[0]");
  print STDERR "XmlPlugin::Core - $_[0]\n";
}

sub _entityEncode {
  my ($text, $extra) = @_;
  $extra = '' unless defined $extra;

  return unless defined $text;

  $text =~ s/([[\x01-\x09\x0b\x0c\x0e-\x1f"%&\$'*<=>@\]_\|$extra])/'&#'.ord($1).';'/ge;
  return $text;
}

1;
