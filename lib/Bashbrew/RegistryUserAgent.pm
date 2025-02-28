package Bashbrew::RegistryUserAgent;
use Mojo::Base -base, -signatures;

use Mojo::Promise;
use Mojo::UserAgent;

# https://github.com/tianon/dockerhub-public-proxy
has hubProxy => ''; # "https://dockerhub-public-proxy.example.com"

# whether we should assume the registries we talk to are "insecure" (useful for hitting a localhost registry)
has insecure => undef;

has defaultRetries => 10;

has ua => sub {
	my $ua = Mojo::UserAgent->new->max_redirects(10)->connect_timeout(120)->inactivity_timeout(120);
	$ua->transactor->name(join ' ',
		# https://github.com/docker/docker/blob/v1.11.2/dockerversion/useragent.go#L13-L34
		'docker/1.11.2',
		'go/1.6.2',
		'git-commit/v1.11.2',
		'kernel/4.4.11',
		'os/linux',
		'arch/amd64',
		# BOGUS USER AGENTS FOR THE BOGUS USER AGENT THRONE
	);
	return $ua;
};

# https://github.com/docker/distribution/blob/v2.7.1/docs/spec/manifest-v2-2.md#media-types
use constant MEDIA_MANIFEST_LIST => 'application/vnd.docker.distribution.manifest.list.v2+json';
use constant MEDIA_MANIFEST_V2   => 'application/vnd.docker.distribution.manifest.v2+json';
use constant MEDIA_MANIFEST_V1   => 'application/vnd.docker.distribution.manifest.v1+json';
use constant MEDIA_FOREIGN_LAYER => 'application/vnd.docker.image.rootfs.foreign.diff.tar.gzip';
# https://github.com/opencontainers/image-spec/blob/v1.0.2/media-types.md
use constant MEDIA_OCI_INDEX_V1    => 'application/vnd.oci.image.index.v1+json';
use constant MEDIA_OCI_MANIFEST_V1 => 'application/vnd.oci.image.manifest.v1+json';

sub is_media_image_manifest ($mediaType) {
	return $mediaType eq MEDIA_OCI_MANIFEST_V1 || $mediaType eq MEDIA_MANIFEST_V2 || $mediaType eq MEDIA_MANIFEST_V1;
}
sub is_media_image_list ($mediaType) {
	return $mediaType eq MEDIA_OCI_INDEX_V1 || $mediaType eq MEDIA_MANIFEST_LIST;
}

# this is "normally" handled for us by https://github.com/tianon/dockerhub-public-proxy but is necessary for alternative registries
my $acceptHeader = [
	MEDIA_MANIFEST_LIST,
	MEDIA_MANIFEST_V2,
	MEDIA_MANIFEST_V1,
	MEDIA_OCI_INDEX_V1,
	MEDIA_OCI_MANIFEST_V1,
	'*/*', # Docker Hub doesn't (currently, as of 2022-10-20) support this catch-all, but other registries do
];

sub _retry_simple_req_p ($self, $tries, $method, @args) {
	--$tries;

	my $methodP = lc($method) . '_p';
	my $prom = $self->ua->$methodP(@args);
	if ($tries > 0) {
		$prom = $prom->then(sub ($tx) {
			return $tx if !$tx->error || $tx->res->code == 404 || $tx->res->code == 401;

			say {*STDERR} "Note: retrying a request (@{[ $tx->req->url . ' -> ' . $tx->res->code ]}); $tries tries remain"; # TODO allow these notices to be disabled?

			# retry after a small delay (longer in the face of "429 Too Many Requests")
			return Mojo::Promise->timer(
				$tx->res->code == 429
				? 1
				: 0.1
			)->then(sub { return $self->_retry_simple_req_p($tries, $method, @args) });
		});
	}
	return $prom;
}

sub retry_simple_req_p ($self, $method, @args) {
	return $self->_retry_simple_req_p($self->defaultRetries, $method, @args);
}

sub ref_url ($self, $ref, $urlType = undef, $direct = 0) {
	my $obj = $ref->obj(undef);
	die "ref '$ref' missing tag or digest" if $urlType && !defined $obj;
	return (
		(!$direct && !$ref->docker_host && $self->hubProxy)
		? $self->hubProxy
		: ($self->insecure ? 'http' : 'https') . '://' . $ref->registry_host
	) . '/v2/' . $ref->canonical_repo . ($urlType ? '/' . $urlType . '/' . $obj : '');
}

sub get_manifest_p ($self, $ref, $tries = $self->defaultRetries) {
	--$tries;
	my $lastTry = $tries < 1;

	state %cache;
	if ($ref->digest && $cache{$ref->digest}) {
		return Mojo::Promise->resolve($cache{$ref->digest});
	}

	return $self->_retry_simple_req_p($tries, GET => $self->ref_url($ref, 'manifests'), { Accept => $acceptHeader })->then(sub ($tx) {
		return if $tx->res->code == 404 || $tx->res->code == 401;

		if (!$lastTry && $tx->res->code != 200) {
			return $self->get_manifest_p($ref, $tries);
		}
		die "unexpected response code fetching '$ref': " . $tx->res->code . ' -- ' . $tx->res->message unless $tx->res->code == 200;

		my $digest = $tx->res->headers->header('Docker-Content-Digest') or die "'$ref' is missing 'Docker-Content-Digest' header";
		die "malformed 'docker-content-digest' header in '$ref': '$digest'" unless $digest =~ m!^sha256:!; # TODO reuse Bashbrew::RemoteImageRef digest validation

		my $manifest = $tx->res->json or die "'$ref' has bad or missing JSON";
		my $size = int($tx->res->headers->content_length);
		my $verbatim = $tx->res->body;

		return $cache{$digest} = {
			digest => $digest,
			manifest => $manifest,
			size => $size,
			verbatim => $verbatim,

			mediaType => (
				$manifest->{schemaVersion} == 1
				? MEDIA_MANIFEST_V1
				: (
					$manifest->{schemaVersion} == 2
					? $manifest->{mediaType}
					: die "unknown schemaVersion for '$ref': " . $manifest->{schemaVersion}
				)
			),
		};
	});
}

sub get_blob_p ($self, $ref, $tries = $self->defaultRetries) {
	die "missing blob digest for '$ref'" unless $ref->digest;

	--$tries;
	my $lastTry = $tries < 1;

	state %cache;
	return Mojo::Promise->resolve($cache{$ref->digest}) if $cache{$ref->digest};

	return $self->_retry_simple_req_p($tries, GET => $self->ref_url($ref, 'blobs'))->then(sub ($tx) {
		return if $tx->res->code == 404;

		if (!$lastTry && $tx->res->code != 200) {
			return $self->get_blob_p($ref, $tries);
		}
		die "unexpected response code fetching blob from '$ref': " . $tx->res->code . ' -- ' . $tx->res->message unless $tx->res->code == 200;

		return $cache{$ref->digest} = $tx->res->json;
	});
}

sub head_manifest_p ($self, $ref) {
	state %cache;
	if ($ref->digest) {
		my $cacheKey = $ref->to_canonical_string;
		return Mojo::Promise->resolve($cache{$cacheKey}) if $cache{$cacheKey};
	}

	return $self->_retry_simple_req_p($self->defaultRetries, HEAD => $self->ref_url($ref, 'manifests'), { Accept => $acceptHeader })->then(sub ($tx) {
		return undef if $tx->res->code == 404 || $tx->res->code == 401;
		die "unexpected response code HEADing manifest '$ref': " . $tx->res->code . ' -- ' . $tx->res->message unless $tx->res->code == 200;
		my $digest = $tx->res->headers->header('Docker-Content-Digest');
		die "missing digest from HEADing manifest '$ref'" unless $digest;
		my $cacheKey = $ref->clone->digest($digest)->to_canonical_string;
		return $cache{$cacheKey} = $digest;
	});
}

sub head_blob_p ($self, $ref) {
	die "missing blob digest for HEAD '$ref'" unless $ref->digest;

	my $cacheKey = $ref->to_canonical_string;
	state %cache;
	return Mojo::Promise->resolve($cache{$cacheKey}) if $cache{$cacheKey};

	return $self->_retry_simple_req_p($self->defaultRetries, HEAD => $self->ref_url($ref, 'blobs'))->then(sub ($tx) {
		return 0 if $tx->res->code == 404 || $tx->res->code == 401;
		die "unexpected response code HEADing blob '$ref': " . $tx->res->code . ' -- ' . $tx->res->message unless $tx->res->code == 200;
		return $cache{$cacheKey} = 1;
	});
}

# parse "~/.docker/config.json" given a ref and return the "user:pass" credential string for the registry it points to
sub get_creds ($self, $ref) {
	die 'missing DOCKER_CONFIG or HOME environment variable' unless $ENV{DOCKER_CONFIG} or $ENV{HOME};

	my $config = Mojo::File->new(($ENV{DOCKER_CONFIG} || ($ENV{HOME} . '/.docker')) . '/config.json')->slurp;
	die 'missing or empty ".docker/config.json" file' unless $config;

	my $json = Mojo::JSON::decode_json($config);
	die 'invalid ".docker/config.json" file' unless $json && $json->{auths};

	my @registryHosts = ( $ref->registry_host );
	push @registryHosts, 'index.docker.io', 'docker.io' if !$ref->docker_host; # https://github.com/moby/moby/blob/fc01c2b481097a6057bec3cd1ab2d7b4488c50c4/registry/config.go#L397-L404

	for my $registry (keys %{ $json->{auths} }) {
		next unless $json->{auths}{$registry};

		my $auth = $json->{auths}{$registry}{auth};
		next unless $auth;

		# https://github.com/moby/moby/blob/34b56728ed7101c6b3cc0405f5fd6351073a8253/registry/auth.go#L202-L235
		$registry =~ s! ^ https?:// | / .+ $ !!gx;

		for my $registryHost (@registryHosts) {
			if ($registry eq $registryHost) {
				$auth = Mojo::Util::b64_decode($auth);
				return $auth if $auth && $auth =~ m!:!;
			}
		}
	}

	die 'failed to find credentials for "' . $ref->canonical_host . '" in ".docker/config.json" file';
}

sub authenticated_registry_req_p ($self, $method, $ref, $scope, $url, $contentType = undef, $payload = undef, $tries = $self->defaultRetries) {
	--$tries;
	my $lastTry = $tries < 1;

	my %headers = ($contentType ? ('Content-Type' => $contentType) : ());

	state %tokens;
	if (my $token = $tokens{$scope}) {
		$headers{Authorization} = "Bearer $token";
	}

	my $methodP = lc($method) . '_p';
	my $fullUrl = $self->ref_url($ref->clone->digest(undef)->tag(undef), undef, 1) . '/' . $url;
	return $self->ua->$methodP($fullUrl, \%headers, ($payload ? $payload : ()))->then(sub ($tx) {
		if (!$lastTry && $tx->res->code == 401) {
			# "Unauthorized" -- we must need to go fetch a token for this registry request (so let's go do that, then retry the original registry request)
			my $auth = $tx->res->headers->www_authenticate;
			die "unexpected WWW-Authenticate header ('$url'): $auth" unless $auth =~ m{ ^ Bearer \s+ (\S.*) $ }x;
			my $realm = $1;
			my $authUrl = Mojo::URL->new;
			while ($realm =~ m{
				# key="val",
				([^=]+)
				=
				"([^"]+)"
				,?
			}xg) {
				my ($key, $val) = ($1, $2);
				next if $key eq 'error' and $val eq 'invalid_token'; # just ignore the error if it's "invalid_token" because it likely means our token expired mid-push so we just need to renew
				die "WWW-Authenticate header error ('$url'): $val ($auth)" if $key eq 'error';
				if ($key eq 'realm') {
					$authUrl->base(Mojo::URL->new($val));
				}
				else {
					$authUrl->query->append($key => $_) for split / /, $val; # Docker's auth server expects "scope=xxx&scope=yyy" instead of "scope=xxx%20yyy"
				}
			}
			$authUrl = $authUrl->to_abs;
			say {*STDERR} "Note: grabbing auth token from $authUrl (for $fullUrl; $tries tries remain)"; # TODO allow these notices to be disabled?
			return $self->_retry_simple_req_p($tries, GET => $authUrl->userinfo($self->get_creds($ref))->to_unsafe_string)->then(sub ($tx) {
				if (my $error = $tx->error) {
					die "registry authentication error ('$url'): " . ($error->{code} ? $error->{code} . ' -- ' : '') . $error->{message};
				}

				$tokens{$scope} = $tx->res->json->{token};
				return $self->authenticated_registry_req_p($method, $ref, $scope, $url, $contentType, $payload, $tries);
			});
		}

		if (!$lastTry && $tx->res->code != 200) {
			return $self->authenticated_registry_req_p($method, $ref, $scope, $url, $contentType, $payload, $tries);
		}

		if (my $error = $tx->error) {
			$tx->req->headers->authorization('REDATCTED') if $tx->req->headers->authorization;
			die "registry request error ('$url'): " . ($error->{code} ? $error->{code} . ' -- ' : '') . $error->{message} . "\n\nREQUEST:\n" . $tx->req->headers->to_string . "\n\n" . $tx->req->body . "\n\nRESPONSE:\n" . $tx->res->to_string . "\n";
		}

		return $tx;
	});
}

1;
