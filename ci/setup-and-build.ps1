param(
  [string] $game_home = (get-item "$($PSScriptRoot)").parent.FullName, ## The root of the ThirdPersonShooter repo
  [string] $gdk_repo = "git@github.com:spatialos/UnrealGDK.git",
  [string] $gcs_publish_bucket = "io-internal-infra-unreal-artifacts-production/UnrealEngine",
  [string] $gdk_branch_name = "master",
  [string] $deployment_launch_configuration = "one_worker_test.json",
  [string] $deployment_snapshot_path = "snapshots/default.snapshot",
  [string] $deployment_cluster_region = "eu"
)

$ErrorActionPreference = 'Stop'

function Write-Log() {
  param(
    [string] $msg,
    [Parameter(Mandatory=$false)] [bool] $expand = $false
  )
  if ($expand) {
      Write-Output "+++ $($msg)"
  } else {
      Write-Output "--- $($msg)"
  }
}

function Start-Event() {
    param(
        [string] $event_name,
        [string] $event_parent
    )

    # Start this tracing span.
    Start-Process -NoNewWindow "imp-ci" -ArgumentList @(`
        "events", "new", `
        "--name", "$($event_name)", `
        "--child-of", "$($event_parent)"
    ) | Out-Null

    Write-Log "--- $($event_name)"
}

function Finish-Event() {
    param(
        [string] $event_name,
        [string] $event_parent
    )

    # Emit the end marker for this tracing span.
    Start-Process -NoNewWindow "imp-ci"  -ArgumentList @(`
        "events", "new", `
        "--name", "$($event_name)", `
        "--child-of", "$($event_parent)"
    ) | Out-Null
}


# Fetch the version of Unreal Engine we need
pushd "ci"
    $unreal_version = Get-Content -Path "unreal-engine.version" -Raw
    Write-Log "Using Unreal Engine version: $($unreal_version)"
popd

## Create an UnrealEngine directory if it doesn't already exist
New-Item -Name "UnrealEngine" -ItemType Directory -Force

Start-Event "download-unreal-engine" "build-unreal-gdk-:windows:"
    pushd "UnrealEngine"
        Write-Log "Downloading the Unreal Engine artifacts from GCS"
        $gcs_unreal_location = "$($unreal_version).zip"

        $gsu_proc = Start-Process -Wait -PassThru -NoNewWindow "gsutil" -ArgumentList @(`
            "cp", `
            "gs://$($gcs_publish_bucket)/$($gcs_unreal_location)", `
            "$($unreal_version).zip" `
        )
        if ($gsu_proc.ExitCode -ne 0) {
            Write-Log "Failed to download Engine artifacts. Error: $($gsu_proc.ExitCode)"
            Throw "Failed to download Engine artifacts"
        }

        Write-Log "Unzipping Unreal Engine"
        $zip_proc = Start-Process -Wait -PassThru -NoNewWindow "7z" -ArgumentList @(`
        "x", `  
        "$($unreal_version).zip" `    
        )   
        if ($zip_proc.ExitCode -ne 0) { 
            Write-Log "Failed to unzip Unreal Engine. Error: $($zip_proc.ExitCode)" 
            Throw "Failed to unzip Unreal Engine."  
        } 

        $unreal_path = "$($game_home)\UnrealEngine"
        Write-Log "Setting UNREAL_HOME environment variable to $($unreal_path)"
        [Environment]::SetEnvironmentVariable("UNREAL_HOME", "$($unreal_path)", "Machine")

        $clang_path = "$($game_home)\UnrealEngine\ClangToolchain"
        Write-Log "Setting LINUX_MULTIARCH_ROOT environment variable to $($clang_path)"
        [Environment]::SetEnvironmentVariable("LINUX_MULTIARCH_ROOT", "$($clang_path)", "Machine")
    popd
Finish-Event "download-unreal-engine" "build-unreal-gdk-:windows:"


pushd "$($game_home)"
    Start-Event "clone-gdk-plugin" "clone-gdk-plugin-:windows:"
        pushd "Game"
            New-Item -Name "Plugins" -ItemType Directory -Force
            pushd "Plugins"
            Start-Process -Wait -PassThru -NoNewWindow -FilePath "git" -ArgumentList @(`
                "clone", `
                "git@github.com:spatialos/UnrealGDK.git", `
                "--depth 1", `
                "-b $gdk_branch_name" # TODO: Remove this once we're on master
            )
            popd
        popd
    Finish-Event "clone-gdk-plugin" "clone-gdk-plugin-:windows:"

    Start-Event "set-up-gdk-plugin" "set-up-gdk-plugin-:windows:"
        pushd "Game/Plugins/UnrealGDK"
            # Set the required variables for the GDK's setup script to use
            $gdk_home = Convert-Path .
            $msbuild_exe = "${env:ProgramFiles(x86)}\MSBuild\14.0\bin\MSBuild.exe"

            # Invoke the setup script
            &"$($game_home)\Game\Plugins\UnrealGDK\ci\setup-gdk.ps1"
        popd
    Finish-Event "set-up-gdk-plugin" "set-up-gdk-plugin-:windows:"

    Start-Event "generate-schema"
        pushd "UnrealEngine/Engine/Binaries/Win64"
            Start-Process -Wait -PassThru -NoNewWindow -FilePath "UE4Editor.exe" -ArgumentList @(`
                "$($game_home)/Game/ThirdPersonShooter.uproject", `
                "-run=GenerateSchemaAndSnapshots", `
                "-MapPaths=`"/Maps/TPS-Start_Small`""
            )

            New-Item -Path "$($game_home)\spatial\schema\unreal" -Name "gdk" -ItemType Directory -Force
            Copy-Item "$($game_home)\Game\Plugins\UnrealGDK\SpatialGDK\Extras\schema\*" -Destination "$($game_home)\spatial\schema\unreal\gdk"
        popd
    Finish-Event "generate-schema"

    Start-Event "build-project" "build-project-:windows:"
        # Allow the GDK plugin to find the engine
        $env:UNREAL_HOME = "$($game_home)\UnrealEngine\"

        $build_client_proc = Start-Process -PassThru -NoNewWindow -FilePath "$($game_home)\Game\Plugins\UnrealGDK\SpatialGDK\Build\Scripts\BuildWorker.bat" -ArgumentList @(`
            "ThirdPersonShooter", `
            "Win64", `
            "Development", `
            "ThirdPersonShooter.uproject"
        )       
        $build_client_handle = $build_client_proc.Handle
        Wait-Process -Id (Get-Process -InputObject $build_client_proc).id
        if ($build_client_proc.ExitCode -ne 0) {
            Write-Log "Failed to build Win64 Development Client. Error: $($build_client_proc.ExitCode)"
            Throw "Failed to build Win64 Development Client"
        }

        $build_server_proc = Start-Process -PassThru -NoNewWindow -FilePath "$($game_home)\Game\Plugins\UnrealGDK\SpatialGDK\Build\Scripts\BuildWorker.bat" -ArgumentList @(`
            "ThirdPersonShooterServer", `
            "Linux", `
            "Development", `
            "ThirdPersonShooter.uproject"
        )       
        $build_server_handle = $build_server_proc.Handle
        Wait-Process -Id (Get-Process -InputObject $build_server_proc).id
        if ($build_server_proc.ExitCode -ne 0) {
            Write-Log "Failed to build Linux Development Server. Error: $($build_server_proc.ExitCode)"
            Throw "Failed to build Linux Development Server"
        }
    Finish-Event "build-unreal-gdk" "build-unreal-gdk-:windows:"

    Start-Event "deploy-game"
        pushd "spatial"
            $deployment_name = "thirdpersonshooter-$($BUILDKITE_COMMIT)"
            $assembly_name = "$($deployment_name)_asm"

            Start-Process -Wait -PassThru -NoNewWindow -FilePath "spatial" -ArgumentList @(`
                "build", `
                "build-config"
            )

            Start-Process -Wait -PassThru -NoNewWindow -FilePath "spatial" -ArgumentList @(`
                "cloud", `
                "upload", `
                "$($assembly_name)", `
                "--force"
            )

            Start-Process -Wait -PassThru -NoNewWindow -FilePath "spatial" -ArgumentList @(`
                "cloud", `
                "launch", `
                "$($assembly_name)", `
                "$($deployment_launch_configuration)", `
                "$($deployment_name)", `
                "--snapshot=$($deployment_snapshot_path)", `
                "--cluster_region=$($deployment_cluster_region)"
            )
        popd
    Finish-Event "deploy-game"

popd

