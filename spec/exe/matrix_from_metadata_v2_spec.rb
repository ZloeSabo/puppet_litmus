# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'matrix_from_metadata_v2' do
  context 'without arguments' do
    let(:result) { run_matrix_from_metadata_v2 }

    it 'run successfully' do
      expect(result.status_code).to eq 0
    end

    it 'generates the matrix' do
      expect(result.stdout).to include('::warning::Cannot find image for RedHat-8')
      expect(result.stdout).to include('::warning::Cannot find image for Ubuntu-14.04')
      expect(result.stdout).to include(
        [
          '::set-output name=matrix::{',
          '"platforms":[',
          '{"label":"CentOS-6","provider":"provision::docker","image":"litmusimage/centos:6"},',
          '{"label":"Ubuntu-18.04","provider":"provision::docker","image":"litmusimage/ubuntu:18.04"}',
          '],',
          '"collection":[',
          '"puppet6-nightly","puppet7-nightly"',
          ']',
          '}',
        ].join,
      )
      expect(result.stdout).to include(
        '::set-output name=spec_matrix::{"include":[{"puppet_version":"~> 6.0","ruby_version":2.5},{"puppet_version":"~> 7.0","ruby_version":2.7}]}',
      )
      expect(result.stdout).to include("Created matrix with 6 cells:\n  - Acceptance Test Cells: 4\n  - Spec Test Cells: 2")
    end
  end

  context 'with --exclude-platforms ["ubuntu-18.04"]' do
    let(:result) { run_matrix_from_metadata_v2({ '--exclude-platforms' => ['ubuntu-18.04'] }) }

    it 'run successfully' do
      expect(result.status_code).to eq 0
    end

    it 'generates the matrix without excluded platforms' do
      expect(result.stdout).to include('::warning::Cannot find image for RedHat-8')
      expect(result.stdout).to include('::warning::Cannot find image for Ubuntu-14.04')
      expect(result.stdout).to include('::warning::Ubuntu-18.04 was excluded from testing')
      expect(result.stdout).to include(
        [
          '::set-output name=matrix::{',
          '"platforms":[',
          '{"label":"CentOS-6","provider":"provision::docker","image":"litmusimage/centos:6"}',
          '],',
          '"collection":[',
          '"puppet6-nightly","puppet7-nightly"',
          ']',
          '}',
        ].join,
      )
      expect(result.stdout).to include(
        '::set-output name=spec_matrix::{"include":[{"puppet_version":"~> 6.0","ruby_version":2.5},{"puppet_version":"~> 7.0","ruby_version":2.7}]}',
      )
      expect(result.stdout).to include("Created matrix with 4 cells:\n  - Acceptance Test Cells: 2\n  - Spec Test Cells: 2")
    end
  end

  context 'with --exclude-platforms \'["ubuntu-18.04","redhat-8"]\'' do
    let(:result) { run_matrix_from_metadata_v2({ '--exclude-platforms' => ['ubuntu-18.04', 'redhat-8'] }) }

    it 'run successfully' do
      expect(result.status_code).to eq 0
    end

    it 'generates the matrix without excluded platforms' do
      expect(result.stdout).to include('::warning::Cannot find image for Ubuntu-14.04')
      expect(result.stdout).to include('::warning::Ubuntu-18.04 was excluded from testing')
      expect(result.stdout).to include('::warning::RedHat-8 was excluded from testing')
      expect(result.stdout).to include(
        [
          '::set-output name=matrix::{',
          '"platforms":[',
          '{"label":"CentOS-6","provider":"provision::docker","image":"litmusimage/centos:6"}',
          '],',
          '"collection":[',
          '"puppet6-nightly","puppet7-nightly"',
          ']',
          '}',
        ].join,
      )
      expect(result.stdout).to include(
        '::set-output name=spec_matrix::{"include":[{"puppet_version":"~> 6.0","ruby_version":2.5},{"puppet_version":"~> 7.0","ruby_version":2.7}]}',
      )
      expect(result.stdout).to include("Created matrix with 4 cells:\n  - Acceptance Test Cells: 2\n  - Spec Test Cells: 2")
    end
  end
end
