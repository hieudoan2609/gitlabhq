require 'spec_helper'

describe SshHostKey do
  using RSpec::Parameterized::TableSyntax
  include ReactiveCachingHelpers

  let(:key1) do
    'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3UpyF2iLqy1d63M6k3jH1vuEnq/NWtE+o' \
    'rJe1Xn7JoRbduKd6zpsJ0JhBGWgcQK0ph0aGW5PcudzzBSc+SlYfCc4GTaxDtmj41hW0o72m' \
    'NiuDW3oKXXShOiVRde2ZOquH8Z865jGiZIC8BI/bXZD29IGUih0hPu7Rjp70VYiE+35QRf/p' \
    'sD0Ddrz8QUIG3A/2dMzLI5F5ZORk3BIX2F3mJwJOvZxRhR/SqyphDMZ5eZ0EzqbFBCDE6HAB' \
    'Woz9ck8RBGLvCIggmDHj3FmMLcQGMDiy6wKp7QdnBtxjCP6vtE6YPUM223AqsWt+9NTtCfB8' \
    'YdNAH7YcHHOR1FgtSk1x'
  end

  let(:key2) do
    'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLIp+4ciR2YO9f9rpldc7InNQw/TBUtcNb' \
    'J2XR0rr15/5ytz7YM16xXG0Qjx576PNSmqs4gbTrvTuFZak+v1Jx/9deHRq/yqp9f+tv33+i' \
    'aJGCQCX/+OVY7aWgV2R9YsS7XQ4mnv4XlOTEssib/rGAIT+ATd/GcdYSEOO+dh4O09/6O/jI' \
    'MGSeP+NNetgn1nPCnLOjrXFZUnUtNDi6EEKeIlrliJjSb7Jr4f7gjvZnv4RskWHHFo8FgAAq' \
    't0gOMT6EmKrnypBe2vLGSAXbtkXr01q6/DNPH+n9VA1LTV6v1KN/W5CN5tQV11wRSKiM8g5O' \
    'Ebi86VjJRi2sOuYoXQU1'
  end

  # Purposefully ordered so that `sort` will make changes
  let(:known_hosts) do
    <<~EOF
      example.com #{key1} git@localhost
      @revoked other.example.com #{key2} git@localhost
    EOF
  end

  let(:extra) { known_hosts + "foo\nbar\n" }
  let(:reversed) { known_hosts.lines.reverse.join }

  def stub_ssh_keyscan(args, status: true, stdout: "", stderr: "")
    stdin = StringIO.new
    stdout = double(:stdout, read: stdout)
    stderr = double(:stderr, read: stderr)
    wait_thr = double(:wait_thr, value: double(success?: status))

    expect(Open3).to receive(:popen3).with({}, 'ssh-keyscan', *args).and_yield(stdin, stdout, stderr, wait_thr)

    stdin
  end

  let(:project) { build(:project, :mirror) }

  subject(:ssh_host_key) { described_class.new(project: project, url: 'ssh://example.com:2222') }

  describe '#fingerprints', use_clean_rails_memory_store_caching: true do
    it 'returns an array of indexed fingerprints when the cache is filled' do
      stub_reactive_cache(ssh_host_key, known_hosts: known_hosts)

      expected = [key1, key2]
        .map { |data| Gitlab::KeyFingerprint.new(data) }
        .each_with_index
        .map { |key, i| { bits: key.bits, fingerprint: key.fingerprint, type: key.type, index: i } }

      expect(ssh_host_key.fingerprints.as_json).to eq(expected)
    end

    it 'returns an empty array when the cache is empty' do
      expect(ssh_host_key.fingerprints).to eq([])
    end
  end

  describe '#fingerprints', use_clean_rails_memory_store_caching: true do
    it 'returns an array of indexed fingerprints when the cache is filled' do
      stub_reactive_cache(ssh_host_key, known_hosts: known_hosts)

      expect(ssh_host_key.fingerprints.as_json).to eq(
        [
          { bits: 2048, fingerprint: Gitlab::KeyFingerprint.new(key1).fingerprint, type: 'RSA', index: 0 },
          { bits: 2048, fingerprint: Gitlab::KeyFingerprint.new(key2).fingerprint, type: 'RSA', index: 1 }
        ]
      )
    end

    it 'returns an empty array when the cache is empty' do
      expect(ssh_host_key.fingerprints).to eq([])
    end
  end

  describe '#changes_project_import_data?' do
    where(:a, :b, :result) do
      known_hosts | extra       | true
      known_hosts | "foo\n"     | true
      known_hosts | ''          | true
      known_hosts | nil         | true
      known_hosts | known_hosts | false
      reversed    | known_hosts | false
      extra       | "foo\n"     | true
      ''          | ''          | false
      nil         | nil         | false
      ''          | nil         | false
    end

    with_them do
      subject { ssh_host_key.changes_project_import_data? }

      it "(normal)" do
        expect(ssh_host_key).to receive(:known_hosts).and_return(a)
        project.import_data.ssh_known_hosts = b

        is_expected.to eq(result)
      end

      # Comparisons should be symmetrical, so test the reverse too
      it "(reversed)" do
        expect(ssh_host_key).to receive(:known_hosts).and_return(b)
        project.import_data.ssh_known_hosts = a

        is_expected.to eq(result)
      end
    end
  end

  describe '#calculate_reactive_cache' do
    subject(:cache) { ssh_host_key.calculate_reactive_cache }

    it 'writes the hostname to STDIN' do
      stdin = stub_ssh_keyscan(%w[-T 5 -p 2222 -f-])

      cache

      expect(stdin.string).to eq("example.com\n")
    end

    context 'successful key scan' do
      it 'stores the cleaned known_hosts data' do
        stub_ssh_keyscan(%w[-T 5 -p 2222 -f-], stdout: "KEY 1\nKEY 1\n\n# comment\nKEY 2\n")

        is_expected.to eq(known_hosts: "KEY 1\nKEY 2\n")
      end
    end

    context 'failed key scan (exit code 1)' do
      it 'returns a generic error' do
        stub_ssh_keyscan(%w[-T 5 -p 2222 -f-], stdout: 'blarg', status: false)

        is_expected.to eq(error: 'Failed to detect SSH host keys')
      end
    end

    context 'failed key scan (exit code 0)' do
      it 'returns a generic error' do
        stub_ssh_keyscan(%w[-T 5 -p 2222 -f-], stderr: 'Unknown host')

        is_expected.to eq(error: 'Failed to detect SSH host keys')
      end
    end
  end
end
