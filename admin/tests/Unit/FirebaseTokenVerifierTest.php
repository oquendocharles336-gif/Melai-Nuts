<?php

namespace Tests\Unit;

use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseTokenVerifier;
use Tests\Support\FakeFirebase;
use Tests\TestCase;

/** The production verifier against real RS256 tokens signed by the test key pair. */
class FirebaseTokenVerifierTest extends TestCase
{
    private FakeFirebase $fb;

    protected function setUp(): void
    {
        parent::setUp();
        $this->fb = (new FakeFirebase)->install();
    }

    private function verify(string $token): array
    {
        return app(FirebaseTokenVerifier::class)->verify($token);
    }

    private function assertRejected(string $token, string $reason): void
    {
        try {
            $this->verify($token);
            $this->fail('Token was accepted');
        } catch (FirebaseAuthException $e) {
            $this->assertSame($reason, $e->reason, $e->getMessage());
        }
    }

    public function test_valid_token_gives_uid_email_and_verification_flag(): void
    {
        $c = $this->verify($this->fb->token('uid-1', 'Owner@Example.com', true));
        $this->assertSame('uid-1', $c['sub']);
        $this->assertSame('owner@example.com', $c['email']);
        $this->assertTrue($c['email_verified']);
    }

    public function test_expired_token_is_rejected(): void
    {
        $this->assertRejected($this->fb->token('uid-1', 'a@b.c', false, ['exp' => time() - 3600, 'iat' => time() - 7200]), FirebaseAuthException::INVALID_TOKEN);
    }

    public function test_forged_signature_is_rejected(): void
    {
        $other = openssl_pkey_new(['private_key_bits' => 2048]);
        openssl_pkey_export($other, $pem);
        $this->assertRejected($this->fb->token('uid-1', 'a@b.c', false, [], $pem), FirebaseAuthException::INVALID_TOKEN);
    }

    public function test_tampered_payload_is_rejected(): void
    {
        [$h, , $s] = explode('.', $this->fb->token('uid-1', 'a@b.c'));
        $p = rtrim(strtr(base64_encode(json_encode(['sub' => 'owner-uid', 'aud' => FakeFirebase::PROJECT, 'iss' => 'https://securetoken.google.com/'.FakeFirebase::PROJECT, 'exp' => time() + 3600, 'iat' => time()])), '+/', '-_'), '=');
        $this->assertRejected("$h.$p.$s", FirebaseAuthException::INVALID_TOKEN);
    }

    public function test_token_of_another_firebase_project_is_a_configuration_error(): void
    {
        try {
            $this->verify($this->fb->token('uid-1', 'a@b.c', false, ['aud' => 'some-other-project', 'iss' => 'https://securetoken.google.com/some-other-project']));
            $this->fail('accepted');
        } catch (FirebaseAuthException $e) {
            $this->assertSame(FirebaseAuthException::CONFIG, $e->reason);
            $this->assertStringContainsString('some-other-project', $e->getMessage());
            $this->assertStringContainsString('FIREBASE_PROJECT_ID', $e->getMessage());
        }
    }

    public function test_unknown_key_id_unsigned_and_malformed_tokens_are_rejected(): void
    {
        $this->assertRejected($this->fb->token('uid-1', 'a@b.c', false, [], null, 'unknown-kid'), FirebaseAuthException::INVALID_TOKEN);
        $none = rtrim(strtr(base64_encode(json_encode(['alg' => 'none'])), '+/', '-_'), '=').'.'.explode('.', $this->fb->token('u', 'a@b.c'))[1].'.';
        $this->assertRejected($none, FirebaseAuthException::INVALID_TOKEN);
        $this->assertRejected('not-a-jwt', FirebaseAuthException::INVALID_TOKEN);
        $this->assertRejected($this->fb->token('', 'a@b.c'), FirebaseAuthException::INVALID_TOKEN);
    }

    public function test_missing_project_id_is_reported_by_name(): void
    {
        config(['services.firebase.project_id' => null]);
        try {
            $this->verify($this->fb->token('uid-1', 'a@b.c'));
            $this->fail('accepted');
        } catch (FirebaseAuthException $e) {
            $this->assertSame(FirebaseAuthException::CONFIG, $e->reason);
            $this->assertStringContainsString('FIREBASE_PROJECT_ID', $e->getMessage());
        }
    }
}
