package ShinyCMS::Controller::Newsletters;

use Moose;
use namespace::autoclean;

BEGIN { extends 'ShinyCMS::Controller'; }


=head1 NAME

ShinyCMS::Controller::Newsletters

=head1 DESCRIPTION

Controller for ShinyCMS newsletter features.

=head1 METHODS

=cut


=head2 index

Display a list of recent newsletters.

=cut

sub index : Path : Args( 0 ) {
	my ( $self, $c ) = @_;
	
	$c->go( 'view_recent' );
}


=head2 base

Set up path and stash some useful stuff.

=cut

sub base : Chained( '/' ) : PathPart( 'newsletters' ) : CaptureArgs( 0 ) {
	my ( $self, $c ) = @_;
	
	# Stash the upload_dir setting
	$c->stash->{ upload_dir } = $c->config->{ upload_dir };
	
	# Stash the controller name
	$c->stash->{ controller } = 'Newsletters';
}


=head2 get_newsletter

Get the details for a newsletter.

=cut

sub get_newsletter : Chained( 'base' ) : PathPart( '' ) : CaptureArgs( 3 ) {
	my ( $self, $c, $year, $month, $url_title ) = @_;
	
	my $month_start = DateTime->new(
		day   => 1,
		month => $month,
		year  => $year,
	);
	my $month_end = DateTime->new(
		day   => 1,
		month => $month,
		year  => $year,
	);
	$month_end->add( months => 1 );
	
	# Get the newsletter
	$c->stash->{ newsletter } = $c->model( 'DB::Newsletter' )->search({
		url_title => $url_title,
		-and => [
				sent => { '<=' => \'current_timestamp' },
				sent => { '>=' => $month_start->ymd    },
				sent => { '<=' => $month_end->ymd      },
			],
	})->first;
	
	unless ( $c->stash->{ newsletter } ) {
		$c->flash->{ error_msg } = 'Specified newsletter not found.';
		$c->response->redirect( $c->uri_for( '/' ) );
		$c->detach;
	}
	
	# Get newsletter elements
	my @elements = $c->model( 'DB::NewsletterElement' )->search({
		newsletter => $c->stash->{ newsletter }->id,
	});
	$c->stash->{ newsletter_elements } = \@elements;
	
	# Stash site details
	$c->stash->{ site_name } = $c->config->{ site_name };
	$c->stash->{ site_url  } = $c->uri_for( '/' );
	
	# Build up 'elements' structure for use by templates
	foreach my $element ( @elements ) {
		$c->stash->{ elements }->{ $element->name } = $element->content;
	}
}


=head2 get_newsletters

Get a page's worth of newsletters

=cut

sub get_newsletters {
	my ( $self, $c, $page, $count ) = @_;
	
	$page  ||= 1;
	$count ||= 10;
	
	my @newsletters = $c->model( 'DB::Newsletter' )->search(
		{
			sent     => { '<=' => \'current_timestamp' },
		},
		{
			order_by => { -desc => 'sent' },
			page     => $page,
			rows     => $count,
		},
	);

	return \@newsletters;
}


=head2 view_newsletter

View a newsletter.

=cut

sub view_newsletter : Chained( 'get_newsletter' ) : PathPart( '' ) : Args( 0 ) {
	my ( $self, $c ) = @_;
	
	# Set the TT template to use
	$c->stash->{ template } = 'newsletters/newsletter-templates/'. $c->stash->{ newsletter }->template->filename;
}


=head2 view_newsletters

Display a page of newsletters.

=cut

sub view_newsletters : Chained( 'base' ) : PathPart( 'view' ) : OptionalArgs( 2 ) {
	my ( $self, $c, $page, $count ) = @_;
	
	$page  ||= 1;
	$count ||= 10;
	
	my $newsletters = $self->get_newsletters( $c, $page, $count );
	
	$c->stash->{ page_num   } = $page;
	$c->stash->{ post_count } = $count;
	
	$c->stash->{ newsletters } = $newsletters;
}


=head2 view_recent

Display recent blog posts.

=cut

sub view_recent : Chained( 'base' ) : PathPart( '' ) : Args( 0 ) {
	my ( $self, $c ) = @_;
	
	$c->go( 'view_newsletters', [ 1, 10 ] );
}


# ========== ( Mailing Lists ) ==========

=head2 lists

View a list of all mailing lists this user is subscribed to.

=cut

sub lists : Chained( 'base' ) : PathPart( 'lists' ) : Args() {
	my ( $self, $c, $token ) = @_;
	
	my $mail_recipient;
	my $email;
	if ( $token ) {
		# Get email address that matches URL token
		$mail_recipient = $c->model('DB::MailRecipient')->find({
			token => $token,
		});
		if ( $mail_recipient ) {
			# Dig out the email address
			$email = $mail_recipient->email;
			# Put the token in the stash for inclusion in form
			$c->{ stash }->{ token } = $token;
		}
		else {
			$c->flash->{ error_msg } = 'Subscriber not found.';
		}
	}
	elsif ( $c->user_exists ) {
		# Use the logged-in user's email address
		$email = $c->user->email;
		$mail_recipient = $c->model( 'DB::MailRecipient' )->search({
			email => $email,
		})->first;
		$c->{ stash }->{ token } = $mail_recipient->token;
	}
	
	# Fetch the list of mailing lists for this user
	if ( $email and $mail_recipient ) {
		my $list_recipients = $mail_recipient->list_recipients;
		my @user_lists;
		my @subbed_list_ids;
		while ( my $list_recipient = $list_recipients->next ) {
			push @user_lists, $list_recipient->list;
			push @subbed_list_ids, $list_recipient->list->id;
		}
		$c->{ stash }->{ user_lists } = \@user_lists;
		
		# Fetch details of private mailing lists that this user is subscribed to
		my $private_lists = $c->model( 'DB::MailingList' )->search({
			user_can_sub   => 0,
			user_can_unsub => 1,
			id => { -in => \@subbed_list_ids },
		});
		$c->{ stash }->{ private_lists } = $private_lists;
	}
	else {
		# If no email address, treat as new subscriber; no existing subscriptions, 
		# and need to get email address (and, optionally, name) from them as well.
		
		# TODO: think about this^ some more - currently it allows DOS attacks,  
		# and possibly leaks private data.  For now, bail out here.
		$c->detach;
	}
	
	# Fetch the details of all public mailing lists
	my $public_lists = $c->model( 'DB::MailingList' )->search({
		user_can_sub => 1,
	});
	$c->{ stash }->{ public_lists } = $public_lists;
}


=head2 generate_email_token

Generate an email address token.

=cut

sub generate_email_token {
	my ( $self, $c, $email, $timestamp ) = @_;
	
	my $md5 = Digest::MD5->new;
	$md5->add( $email, $timestamp );
	my $code = $md5->hexdigest;
	
	return $code;
}


=head2 lists_update

Update which mailing lists this user is subscribed to.

=cut

sub lists_update : Chained( 'base' ) : PathPart( 'lists/update' ) : Args( 0 ) {
	my ( $self, $c ) = @_;
	
	# Get the email token from the form, if included
	my $token = $c->request->param('token') || undef;
	
	my $email;
	if ( $token ) {
		# Get email address that matches URL token
		my $mail_recipient = $c->model('DB::MailRecipient')->find({
			token => $token,
		});
		if ( $mail_recipient ) {
			# Dig out the email address
			$email = $mail_recipient->email;
		}
	}
	else {
		# Get the email address from the form, if given
# TODO: figure out what I'm doing about non-logged-in users with no token
#		$email = $c->request->param('email') || undef;
	}
	# Use the logged-in user's email address if one hasn't been specified
	$email = $c->user->email if $c->user_exists and not $email;
	
	# Bail out if we still don't have an email address
	unless ( $email ) {
		$c->flash->{ error_msg } = 'No email address specified.';
		my $uri = $c->uri_for( 'lists' );
		$c->response->redirect( $uri );
		$c->detach;
	}
	
	# Fetch the list of existing subscriptions for this address
	my $mail_recipient = $c->model('DB::MailRecipient')->find({
		email => $email,
	});
	unless ( $mail_recipient ) {
		my $now = DateTime->now;
		my $token = $self->generate_email_token(
			$c,
			$email,
			$now->datetime,
		);
		# Create new mail recipient
		$mail_recipient = $c->model('DB::MailRecipient')->create({
			email => $email,
			token => $token,
			name  => $c->request->param('name') || undef,
		});
	}
	my $list_recipients = $mail_recipient->list_recipients;
	
	# Get the sub/unsub details from form
	my %params = %{ $c->request->params };
	my @keys = keys %params;
	
	# Delete existing (old) subscriptions
	$list_recipients->delete;
	
	# Create new subscriptions
	foreach my $key ( @keys ) {
		next unless $key =~ m/^list_(\d+)/;
		my $list_id = $1;
		$list_recipients->create({ list => $list_id });
	}
	
	my $uri;
	$uri = $c->uri_for( 'lists', $token ) if     $token;
	$uri = $c->uri_for( 'lists'         ) unless $token;
	$c->response->redirect( $uri );
}



=head1 AUTHOR

Denny de la Haye <2013@denny.me>

=head1 COPYRIGHT

ShinyCMS is copyright (c) 2009-2013 Shiny Ideas (www.shinyideas.co.uk).

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it 
under the terms of the GNU Affero General Public License as published by 
the Free Software Foundation, either version 3 of the License, or (at your 
option) any later version.

You should have received a copy of the GNU Affero General Public License 
along with this program (see docs/AGPL-3.0.txt).  If not, see 
http://www.gnu.org/licenses/

=cut

__PACKAGE__->meta->make_immutable;

1;

