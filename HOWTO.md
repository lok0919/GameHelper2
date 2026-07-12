# How to Add a Plugin Submodule

This guide explains how to add a new plugin submodule to the GameHelper2 workspace so that it integrates and compiles automatically with the rest of the project.

---

## Method 1: Automated (Recommended)

An automated target has been added to the [Makefile](file:///home/sam/Works/POE2/GameHelper2-github/Makefile) that simplifies the process. Run the following command from the root of the repository:

```bash
make add-plugin REPO=<repository_url>
```

### Example:
```bash
make add-plugin REPO=git@github.com:yokkenUA/Atlas.git
```

This target automatically:
1. Infers the plugin name from the repository URL.
2. Clones the repository as a submodule under `Plugins/<PluginName>`.
3. Invokes the containerized .NET SDK via Podman to register the `<PluginName>.csproj` under the `Plugins` solution folder in `GameOverlay.sln`.

---

## Method 2: Manual Steps

If you need to perform the steps manually (or don't want to use `make`), follow these instructions:

### 1. Add the Git Submodule
Run `git submodule add` to clone the plugin repository into the `Plugins/` folder:
```bash
git submodule add <repository_url> Plugins/<PluginName>
```
*(e.g., `git submodule add git@github.com:yokkenUA/Atlas.git Plugins/Atlas`)*

### 2. Add the Project to the Solution
Add the plugin's C# project file (`.csproj`) to the main `GameOverlay.sln` solution using the containerized .NET SDK. Make sure to specify the `--solution-folder Plugins` argument to keep the solution structure organized:
```bash
podman run --rm \
	-v "$(pwd):/workspace:Z" \
	-v "$HOME/.nuget/packages:/tmp/nuget:Z" \
	-e NUGET_PACKAGES=/tmp/nuget \
	-w /workspace \
	--userns=keep-id \
	--security-opt label=disable \
	mcr.microsoft.com/dotnet/sdk:10.0 \
	dotnet sln GameOverlay.sln add Plugins/<PluginName>/<PluginName>.csproj --solution-folder Plugins
```
*(Replace `<PluginName>` with your plugin directory name)*

---

## Build and Verify

Once added, build the entire solution to compile and stage the new plugin DLL into the overlay's output directory:

```bash
make build
```

This compiles the new plugin and copies it into `GameHelper/bin/Debug/net10.0-windows/win-x64/Plugins/<PluginName>/`.
