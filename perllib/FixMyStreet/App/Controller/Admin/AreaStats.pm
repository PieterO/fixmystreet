package FixMyStreet::App::Controller::Admin::AreaStats;
use Moose;
use namespace::autoclean;
use List::Util qw(sum);

BEGIN { extends 'Catalyst::Controller'; }

sub begin : Private {
    my ( $self, $c ) = @_;

    $c->forward('/admin/begin');
}

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;

    my $user = $c->user;

    if ($user->is_superuser) {
        $c->forward('/admin/fetch_all_bodies');
    } elsif ( $user->from_body ) {
        $c->forward('load_user_body', [ $user->from_body->id ]);
        $c->stash->{body_id} = $user->from_body->id;
        if ($user->area_id) {
            $c->stash->{area_id} = $user->area_id;
            $c->visit( 'stats', [ $user->from_body->id, $user->area_id ], [] );
        } else {
            $c->visit( 'list_wards', [ $user->from_body->id ], [] );
        }
    } else {
        $c->detach( '/page_error_404_not_found' );
    }
}

sub check_user : Private {
    my ( $self, $c, $body_id, $area_id ) = @_;

    my $user = $c->user;

    if ($user->is_superuser) {
        return;
    }

    if ($body_id and $user->from_body->id eq $body_id) {
        if (not $user->area_id) {
            return;
        } elsif ($area_id and $user->area_id eq $area_id) {
            return;
        }
    }

    $c->detach( '/page_error_404_not_found' );
}

sub body_base : Chained('/') : PathPart('admin/areastats') : CaptureArgs(1) {
    my ($self, $c, $body_id) = @_;
    $c->stash->{body_id} = $body_id;
    $c->forward('/admin/lookup_body');
    $c->stash->{areas} = mySociety::MaPit::call('area/children', [ $body_id ] );
}

sub list_wards : Chained('body_base') : PathPart('') : Args(0) {
    my ( $self, $c ) = @_;

    my $user = $c->user;

    $c->forward('check_user', [$c->stash->{body_id}]);
}

sub body_stats : Chained('body_base') : PathPart('stats') : Args(0) {
    my ($self, $c) = @_;
    my $user = $c->user;

    $c->forward('check_user', [$c->stash->{body_id}]);
    $c->stash->{area_id} = $c->stash->{body}->id;
    $c->forward('stats');
}

sub ward_stats : Chained('body_base') :PathPart('') : Args(1) {
    my ($self, $c, $area_id) = @_;
    my $user = $c->user;

    $c->forward('check_user', [$c->stash->{body_id}, $area_id]);

    $c->stash->{area_id} = $area_id;
    $c->forward('stats');
}

sub stats : Private {
    my ($self, $c) = @_;

    my $date = DateTime->now->subtract(days => 30);
    my $area_id = $c->stash->{area_id};
    my $area = mySociety::MaPit::call('area', $area_id );
    my $user = $c->user;

    $c->forward('/admin/fetch_contacts');

    $c->stash->{template} = 'admin/areastats/area.html';
    if ($area->{name}) {
        $c->stash->{area} = $area;

        my $dtf = $c->model('DB')->storage->datetime_parser;
        my $time = $dtf->format_datetime($date);

        my $params = {
            'problem.areas' => { like => "%,$area_id,%" },
            'me.confirmed' => { '>=', $time },
        };

        my $comments = $c->model('DB::Comment')->search(
            $params,
            {
                group_by => [ 'problem_state' ],
                select   => [ 'problem_state', { count => 'me.id' } ],
                as       => [ qw/state state_count/ ],
                join     => 'problem'
            }
        );

        $params = {
            areas => { like => "%,$area_id,%" },
        };

        my $problems = $c->model('DB::Problem')->search(
            $params,
            {
                group_by => [ 'category', 'state' ],
                select   => [ 'category', 'state', { count => 'me.id' } ],
                as       => [ qw/category state state_count/ ],
            }
        );

        my %by_category = map { $_->category => {} } $c->stash->{contacts}->all;
        my %recent_by_category = map { $_->category => 0 } $c->stash->{contacts}->all;

        my $state_map = {};

        $state_map->{$_} = 'open' foreach FixMyStreet::DB::Result::Problem->open_states;
        $state_map->{$_} = 'closed' foreach FixMyStreet::DB::Result::Problem->closed_states;
        $state_map->{$_} = 'fixed' foreach FixMyStreet::DB::Result::Problem->fixed_states;
        $state_map->{$_} = 'scheduled' foreach ('planned', 'action scheduled');

        for my $p ($problems->all) {
            my $meta_state = $state_map->{$p->state};
            $by_category{$p->category}->{$meta_state} += $p->get_column('state_count');
        }

        $params->{'me.confirmed'} = { '>=', $time };

        my $recent_problems = $c->model('DB::Problem')->search(
            $params,
            {
                group_by => [ 'category' ],
                select   => [ 'category', { count => 'me.id' } ],
                as       => [ qw/category category_count/ ],
            }
        );

        for my $p ($recent_problems->all) {
            $recent_by_category{$p->category} += $p->get_column('category_count');
        }


        $c->stash->{$_} = 0 for values %$state_map;
        $c->stash->{open} = $c->model('DB::Problem')->search(
            {
                areas => { like => "%,$area_id,%" },
                confirmed => { '>=' => DateTime::Format::W3CDTF->format_datetime($date) },
            }
        )->count;

        for my $comment ($comments->all) {
            my $meta_state = $state_map->{$comment->get_column('state')};
            $c->stash->{$meta_state} += $comment->get_column('state_count');
        }

        $params = {
            areas => { like => "%,$area_id,%" },
            'problem.confirmed' => { '>=', $time },
        };

        $comments = $c->model('DB::Comment')->search(
            { %$params,
                'me.id' => \"= (select min(id) from comment where me.problem_id=comment.problem_id)",
            },
            {
                select   => [
                    { avg => { extract => "epoch from me.confirmed-problem.confirmed" } },
                ],
                as       => [ qw/time/ ],
                join     => 'problem'
            }
        )->first;
        $c->stash->{average} = int( ($comments->get_column('time')||0)/ 60 / 60 / 24 + 0.5 );

        $c->stash->{by_category} = \%by_category;
        $c->stash->{recent_by_category} = \%recent_by_category;
    } else {
        $c->detach( '/page_error_404_not_found' );
    }
}

sub load_user_body : Private {
    my ($self, $c, $body_id) = @_;

    $c->stash->{body} = $c->model('DB::Body')->find($body_id)
        or $c->detach( '/page_error_404_not_found' );
}

1;
