terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

############################
# 1. CodeCommit Repository #
############################
resource "aws_codecommit_repository" "repo" {
  repository_name = "lambda-ci-cd-repo"
  description     = "Repo CI/CD Lambda"
}

###########################
# 2. IAM Roles            #
###########################

# Role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-ci-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_policy" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess"
}

# Role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline-ci-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "codepipeline.amazonaws.com" }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codepipeline_policy" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodePipelineFullAccess"
}

#######################
# 3. Lambda Function  #
#######################

resource "aws_lambda_function" "lambda" {
  function_name = "lambda-ci-cd"
  role          = aws_iam_role.codebuild_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  # ZIP vacío inicial (Terraform lo exige)
  filename = "empty.zip"
  source_code_hash = filebase64sha256("empty.zip")
}

#################################
# 4. S3 Bucket for Artifacts   #
#################################
resource "random_id" "bucket_id" {
  byte_length = 4
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "lambda-ci-artifacts-${random_id.bucket_id.hex}"
  force_destroy = true
}

#################################
# 5. CodeBuild project          #
#################################

resource "aws_codebuild_project" "build" {
  name         = "lambda-ci-build"
  service_role = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type   = "BUILD_GENERAL1_SMALL"
    image          = "aws/codebuild/standard:6.0"
    type           = "LINUX_CONTAINER"
  }

  source {
    type = "CODEPIPELINE"
  }
}

###########################
# 6. CodePipeline         #
###########################

resource "aws_codepipeline" "pipeline" {
  name     = "lambda-ci-cd-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName = aws_codecommit_repository.repo.repository_name
        BranchName     = "main"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "DeployLambda"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "Lambda"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        FunctionName = aws_lambda_function.lambda.function_name
      }
    }
  }
}
