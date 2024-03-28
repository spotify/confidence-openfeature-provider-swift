# OpenFeature Swift Confidence Provider

A Swift implementation of the [Confidence](https://confidence.spotify.com/) Provider, to be used in conjunction with the [OpenFeature SDK](https://openfeature.dev/docs/reference/concepts/provider).
For documentation related to flags management in Confidence, refer to the [Confidence documentation portal](https://confidence.spotify.com/platform/flags).

Functionalities:
- Managed integration with the Confidence backend
- Prefetch and cache flag evaluations, for fast value reads even when the application is offline
- Automatic data collection (in the backend) about which flags have been accessed by the application

## Dependency Setup

### Xcode Dependencies

You have two options, both start from File > Add Packages... in the code menu.

First, ensure you have your GitHub account added as an option (+ > Add Source Control Account...). You will need to create a [Personal Access Token](https://github.com/settings/tokens) with the permissions defined in the Xcode interface.

1. Add as a remote repository
    * Search for `git@github.com:spotify/confidence-openfeature-provider-swift.git` and click "Add Package"
2. Clone the repository locally
    * Clone locally using your preferred method
    * Use the "Add Local..." button to select the local folder

**Note:** Option 2 is only recommended if you are making changes to the provider, you will also need to add
the relevant OpenFeature SDK dependency manually.

### Swift Package Manager

<!---x-release-please-start-version-->
In the dependencies section of Package.swift add:
```swift
.package(url: "git@github.com:spotify/confidence-openfeature-provider-swift.git", from: "0.1.4")
```
<!---x-release-please-end-->

and in the target dependencies section add:
```swift
.product(name: "ConfidenceProvider", package: "confidence-openfeature-provider-swift"),
.product(name: "Confidence", package: "confidence-openfeature-provider-swift"),
```

## Usage

### Import Modules

Import the `ConfidenceProvider`, the `Confidence` and the `OpenFeature` modules

```swift
import ConfidenceProvider
import Confidence
import OpenFeature
```

### Create and set the Provider

The Confidence Provider instance needs to be created and then set in the global OpenFeatureAPI:
```swift
let provider = ConfidenceFeatureProvider.Builder(credentials: .clientSecret(secret: "mysecret")).build()
let ctx = MutableContext(targetingKey: "myTargetingKey", structure: MutableStructure())
OpenFeatureAPI.shared.setProvider(provider: provider, initialContext:)
```

The `client secret` for your application is obtained in the Confidence portal [link](https://confidence.spotify.com/platform/flags/resolve-flags#creating-a-flag-client).
The evaluation context is the way for the client to specify contextual data that Confidence uses to evaluate rules defined on the flag.

The `setProvider()` function is synchronous and returns immediately, however this does not mean that the provider is ready to be used. An asynchronous network request to the Confidence backend to fetch all the flags configured for your application must be completed by the provider first. The provider will then emit a _READY_ event indicating you can start resolving flags.

There is also an `async/await` compatible API available for waiting the Provider to become ready:
```swift
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider)
```

A utility function is available on the provider to check if the current storage has any values stored - this can be used to determine the best initialization strategy.
```swift
// If we have no cache, then do a fetch first.
var initializationStrategy: InitializationStrategy = .activateAndFetchAsync
if ConfidenceFeatureProvider.isStorageEmpty() {
    initializationStrategy = .fetchAndActivate
}
```

Initialization strategies:
- _activateAndFetchAsync_: the flags in the cached are used for this session, while updated values are fetched and stored on disk for a future session; this means that a READY event is immediately emitted when calling `setProvider()`;
- _fetchAndActivate_: the Provider attempts to refresh the flag cache on disk before exposing the flags; this might prolong the time needed for the Provider to become READY.

To listen for the _READY_ event, you can add an event handler via the `OpenFeatureAPI` shared instance:
```swift
OpenFeatureAPI.shared.observe().sink { event in
    if event == .ready {
        // Provider is ready
    }
}
```

**Note:** if you do attempt to resolve a flag before the READY event is emitted, you may receive the default value with reason `STALE`.

There are other events that are emitted by the provider, see [Provider Events](https://openfeature.dev/specification/types#provider-events) in the Open Feature specification for more details.

### Updating the Evaluation Context

It is possible to update the evaluation context within an application's session via the following API:
```swift
let ctx = MutableContext(targetingKey: "myNewTargetingKey", structure: MutableStructure())
OpenFeatureAPI.shared.setEvaluationContext(evaluationContext: ctx)
```

`setEvaluationContext()` is a synchronous function similar to `setProvider()`. It calls the Confidence backend to fetch the flag evaluations according to the new evaluation context; if the call is successful, it replaces the cache with the new flag data.

**Note:** the initialization strategy is not taken into consideration when calling `setEvaluationContext()`, so it's required to wait for READY before resuming to resolve flags.

**Note:** if you do attempt to resolve a flag before the READY event is emitted, you may receive the default value with reason `STALE`.

**Note:** a "targeting key" in the evaluation context is expected by the Confidence backend where each key gets assigned a different flag's variant (consistently). The `targetingKey` argument is the default place where to provide a targeting key at runtime (as defined by the OpenFeature APIs), but a different custom field inside the `structure` value can also be configured for this purpose in the Confidence portal (making the `targetingKey` argument redundant, i.e. feel free to set it to empty string).

### Handling Provider Errors

When calling `setEvaluationContext()` or `setProvider()` via the `OpenFeatureAPI` an _ERROR_ event can be emitted if something goes wrong.

To listen for the _ERROR_ event, you can add an event handler via the `OpenFeatureAPI` shared instance:
```swift
OpenFeatureAPI.shared.observe().sink { event in
    if event == .error {
        // An error has been emitted
    }
}
```

### Request a flag / value

The `client` is used to retrieve values for the current user / context. For example, retrieving a boolean value for the
flag `flag.my-boolean`:

```swift
let client = OpenFeatureAPI.shared.getClient()
let result = client.getBooleanValue(key: "my-flag.my-boolean", defaultValue: false)
```

Confidence allows each flag value to be a complex data structure including multiple properties of different type. To access a specific flag's property, the dot notation in the example above is used. The full data structure for a flag can be always fetched via:
```swift
let result = client.getObjectValue(key: "my-flag", defaultValue: Value.null)
```

**Note:** if a flag can't be resolved from the local cache, the provider doesn't automatically resort to calling remote. Refreshing the cache from remote only happens when setting a new provider and/or evaluation context in the global OpenFeatureAPI.


### Local overrides

Assume that you have a flag `button` with the schema:
```
{
    color: string,
    size: number
}
```

Then you can locally override the size property by

```swift
OpenFeatureAPI.shared.provider =
    ConfidenceFeatureProvider.Builder(credentials: .clientSecret(secret: "mysecret"))
        .overrides(.field(path: "button.size", variant: "control", value: .integer(4)))
        .build()
```

now, all resolves of `button.size` will return 4.

## Apply events
This Provider automatically emits `apply` events to the Confidence backend once a flag's property is read by the application. This allows Confidence to track who was exposed to what variant and when.

_Note: the `apply` event is only generated for flags that are successfully evaluated (i.e. default values returned due to errors don't generate `apply` events)._
_Note: the `apply` event reports which flag and variant was read by the application, but not which property the application has read from such variant's value._

To avoid generating redundant data, as long as the flags' data returned from the backend for a user remains unchanged, only the first time a flag's property is read will generate an `apply` event. This is true also across restarts of the application.

The Provider stores `apply` events on disk until they are emitted correctly, thus ensuring the apply data reaches the backend even if generated when there is no network available (assuming the device will ever re-connect to the network before the application is deleted by the user).

<!-- Add link to the more detailed documentation on apply events in the Confidence portal once it's ready -->
