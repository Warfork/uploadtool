#!/bin/bash

set +x # Do not leak information

if command -v sha256sum >/dev/null 2>&1 ; then
  shatool="sha256sum"
elif command -v shasum >/dev/null 2>&1 ; then
  shatool="shasum -a 256" # macOS fallback
else
  echo "Neither sha256sum nor shasum is available, cannot check hashes"
fi

# The calling script can set a suffix to be used for
# the tag and release name. This way it is possible to have a release for
# the output of the CI/CD pipeline (marked as 'continuous') and also test
# builds for other branches.
# If this build was triggered by a tag, call the result a Release
if [ ! -z $UPLOADTOOL_SUFFIX ] ; then
  if [ "$UPLOADTOOL_SUFFIX" = "$CIRCLE_TAG" ] ; then
    RELEASE_NAME=$CIRCLE_TAG
    RELEASE_TITLE="Release build ($CIRCLE_TAG)"
    is_prerelease="false"
  else
    RELEASE_NAME="continuous-$UPLOADTOOL_SUFFIX"
    RELEASE_TITLE="Continuous build ($UPLOADTOOL_SUFFIX)"
    is_prerelease="true"
  fi
else
  RELEASE_NAME="continuous" # Do not use "latest" as it is reserved by GitHub
  RELEASE_TITLE="Continuous build"
  is_prerelease="true"
fi

if [ "$CIRCLE_BRANCH" != "master" ] ; then
  echo "Release uploading disabled for pull requests, uploading to transfer.sh instead"
  for FILE in $@ ; do
    BASENAME="$(basename "${FILE}")"
    curl --upload-file $FILE https://transfer.sh/$BASENAME
    echo ""
  done
  $shatool $@
  exit 0
fi

if [ ! -z $CIRCLECI ] ; then
  # We are running on Circle CI
  echo "Running on Circle CI"
  echo "CIRCLE_SHA1: $CIRCLE_SHA1"
  REPO_SLUG="${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
  if [ -z "$GITHUB_TOKEN" ] ; then
    echo "\$GITHUB_TOKEN missing, please set it in the Circle CI settings of this project"
    echo "You can get one from https://github.com/settings/tokens"
    exit 1
  fi
else
  # We are not running on Circle CI
  echo "Not running on Circle CI"
  if [ -z "$REPO_SLUG" ] ; then
    read -s -p "Repo Slug (GitHub and Circle CI username/reponame): " REPO_SLUG
  fi
  if [ -z "$GITHUB_TOKEN" ] ; then
    read -s -p "Token (https://github.com/settings/tokens): " GITHUB_TOKEN
  fi
fi

tag_url="https://api.github.com/repos/$REPO_SLUG/git/refs/tags/$RELEASE_NAME"
tag_infos=$(curl -XGET --header "Authorization: token ${GITHUB_TOKEN}" "${tag_url}")
echo "tag_infos: $tag_infos"
tag_sha=$(echo "$tag_infos" | grep '"sha":' | head -n 1 | cut -d '"' -f 4 | cut -d '{' -f 1)
echo "tag_sha: $tag_sha"

release_url="https://api.github.com/repos/$REPO_SLUG/releases/tags/$RELEASE_NAME"
echo "Getting the release ID..."
echo "release_url: $release_url"
release_infos=$(curl -XGET --header "Authorization: token ${GITHUB_TOKEN}" "${release_url}")
echo "release_infos: $release_infos"
release_id=$(echo "$release_infos" | grep "\"id\":" | head -n 1 | tr -s " " | cut -f 3 -d" " | cut -f 1 -d ",")
echo "release ID: $release_id"
upload_url=$(echo "$release_infos" | grep '"upload_url":' | head -n 1 | cut -d '"' -f 4 | cut -d '{' -f 1)
echo "upload_url: $upload_url"
release_url=$(echo "$release_infos" | grep '"url":' | head -n 1 | cut -d '"' -f 4 | cut -d '{' -f 1)
echo "release_url: $release_url"

if [ "$CIRCLE_SHA1" != "$tag_sha" ] ; then

  echo "CIRCLE_SHA1 != tag_sha, hence deleting $RELEASE_NAME..."

  if [ ! -z "$release_id" ]; then
    delete_url="https://api.github.com/repos/$REPO_SLUG/releases/$release_id"
    echo "Delete the release..."
    echo "delete_url: $delete_url"
    curl -XDELETE \
        --header "Authorization: token ${GITHUB_TOKEN}" \
        "${delete_url}"
  fi

  # echo "Checking if release with the same name is still there..."
  # echo "release_url: $release_url"
  # curl -XGET --header "Authorization: token ${GITHUB_TOKEN}" \
  #     "$release_url"

  if [ "$is_prerelease" = "true" ] ; then
    # if this is a continuous build tag, then delete the old tag
    # in preparation for the new release
    echo "Delete the tag..."
    delete_url="https://api.github.com/repos/$REPO_SLUG/git/refs/tags/$RELEASE_NAME"
    echo "delete_url: $delete_url"
    curl -XDELETE \
        --header "Authorization: token ${GITHUB_TOKEN}" \
        "${delete_url}"
  fi

  echo "Create release..."

  if [ -z "$CIRCLE_BRANCH" ] ; then
    CIRCLE_BRANCH="master"
  fi

  BODY=""

  release_infos=$(curl -H "Authorization: token ${GITHUB_TOKEN}" \
       --data '{"tag_name": "'"$RELEASE_NAME"'","target_commitish": "'"$CIRCLE_SHA1"'","name": "'"$RELEASE_TITLE"'","body": "'"$BODY"'","draft": false,"prerelease": '$is_prerelease'}' "https://api.github.com/repos/$REPO_SLUG/releases")

  echo "$release_infos"

  unset upload_url
  upload_url=$(echo "$release_infos" | grep '"upload_url":' | head -n 1 | cut -d '"' -f 4 | cut -d '{' -f 1)
  echo "upload_url: $upload_url"

  unset release_url
  release_url=$(echo "$release_infos" | grep '"url":' | head -n 1 | cut -d '"' -f 4 | cut -d '{' -f 1)
  echo "release_url: $release_url"

fi # if [ "$CIRCLE_SHA1" != "$tag_sha" ]

if [ -z "$release_url" ] ; then
	echo "Cannot figure out the release URL for $RELEASE_NAME"
	exit 1
fi

echo "Upload binaries to the release..."

for FILE in $@ ; do
  FULLNAME="${FILE}"
  BASENAME="$(basename "${FILE}")"
  curl -H "Authorization: token ${GITHUB_TOKEN}" \
       -H "Accept: application/vnd.github.manifold-preview" \
       -H "Content-Type: application/octet-stream" \
       --data-binary @$FULLNAME \
       "$upload_url?name=$BASENAME"
  echo ""
done

$shatool $@

if [ "$CIRCLE_SHA1" != "$tag_sha" ] ; then
  echo "Publish the release..."

  release_infos=$(curl -H "Authorization: token ${GITHUB_TOKEN}" \
       --data '{"draft": false}' "$release_url")

  echo "$release_infos"
fi # if [ "$CIRCLE_SHA1" != "$tag_sha" ]
