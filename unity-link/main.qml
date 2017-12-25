import QtQuick 2.7
import QtWebSockets 1.0
import Painter 1.0
import "."

/* Allows to link Substance Painter with an external program by using a persistent connection between both programs
 *
 * The connection is based on a WebSocket connection with a simple command protocol: "[COMMAND KEY] [JSON DATA]"
 * List of commands to which this plugin is able to answer:
 * - CREATE_PROJECT: Create a project with specified mesh and link it with Unity
 * - OPEN_PROJECT: Open an existing project and link it with Unity
 * - SEND_PROJECT_INFO: Send back info on the current project (project url and unity link identifier)
 */
PainterPlugin {
  id: root

  property alias linkQuickInterval : settings.linkQuickInterval
  property alias linkDegradedResolution : settings.linkDegradedResolution
  property alias linkHQTreshold : settings.linkHQTreshold
  property alias linkHQInterval : settings.linkHQInterval
  property alias initDelayOnProjectCreation : settings.initDelayOnProjectCreation

  property bool isLinked: false
  property var unityConfig: null
  property var sendMapsButton: null
  property var autoLinkButton: null
  readonly property string linkIdentifierKey: "unity_link_identifier"
  readonly property bool enableAutoLink: autoLinkButton != null ?
    autoLinkButton.enableAutoLink : false

  state: "disconnected"
  states: [
    State {
      name: "disconnected"
      PropertyChanges { target: root; isLinked: false }
    },
    State {
      name: "connected"
      PropertyChanges { target: root; isLinked: true }
    },
    State {
      name: "exporting"
      extend: "connected"
    }
  ]

  Component.onCompleted: {
    sendMapsButton = alg.ui.addToolBarWidget("ButtonSendMaps.qml");
    sendMapsButton.clicked.connect(sendMaps);
    sendMapsButton.enabled = Qt.binding(function() { return root.isLinked; });

    autoLinkButton = alg.ui.addToolBarWidget("ButtonAutoLink.qml");
    autoLinkButton.enabled = Qt.binding(function() { return root.isLinked; });
  }

  onConfigure: settings.visible = true;

  onEnableAutoLinkChanged: {
    if (enableAutoLink) {
      autoLink();
    }
  }

  function disconnect() {
    if (root.unityConfig) {
      alg.log.info(root.unityConfig.applicationName + " client disconnected");
    }
    lqTimer.stop();
    hqTimer.stop();
    root.unityConfig = null;
    root.state = "disconnected"
  }

  function sendMaps(materialsToSend, mapExportConfig) {
    function sendMaterialsMaps() {
      var fullExportPath = "%1/%2".arg(root.unityConfig.workspacePath).arg(root.unityConfig.exportPath);

      function sendMaterialMaps(materialLink, mapsInfos) {
        // Ask the loading of each maps
        var data = {
          material: materialLink.assetPath,
          params: {}
        };
        for (var mapName in mapsInfos) {
          // Convert absolute map path as a workspace relative path
          var mapPath = mapsInfos[mapName];
          if (mapPath.length == 0) continue;

          if (mapName in materialLink.spToUnityProperties) {
            // Convert absolute map path as a workspace relative path
            var relativeMapPath = mapPath.replace(root.unityConfig.workspacePath + "/", '');
            data.params[materialLink.spToUnityProperties[mapName]] = relativeMapPath;
          }
          else {
            alg.log.warn("No defined association with the exported '%1' map".arg(mapName));
          }
        }
        server.sendCommand("SET_MATERIAL_PARAMS", data);
      }

      // Export map from preset
      var materialsName = alg.mapexport.documentStructure().materials.map(
        function(m) { return m.name; }
      ).sort();

      // Filter materials if needed
      if (materialsToSend !== undefined) {
        materialsName = materialsName.filter(
          function(m) { return materialsToSend.indexOf(m) !== -1; }
        );
      }

      for (var i in materialsName) {
        var materialName = materialsName[i];
        if (!(materialName in root.unityConfig.materials)) {
          alg.log.warn("Material %1 is not correctly linked with %2"
            .arg(materialName)
            .arg(root.unityConfig.applicationName));
          continue;
        }

        var materialLink = root.unityConfig.materials[materialName];
        root.state = "exporting"
        var exportData = alg.mapexport.exportDocumentMaps(
          materialLink.exportPreset,
          fullExportPath,
          "png",
          mapExportConfig,
          [materialName]
        );
        root.state = "connected"
        for (var stackPath in exportData) {
          sendMaterialMaps(materialLink, exportData[stackPath]);
        }
      }
    }

    if (root.state == "disconnected") return;
    try {
      sendMaterialsMaps();
    }
    catch(err) {alg.log.exception(err);}
  }

  function getCurrentTextureSet() {
    return alg.mapexport.documentStructure().materials
      .filter(function(m){return m.selected})[0].name;
  }

  function autoLink() {
    if (root.state == "disconnected") return;
    var textureSet = getCurrentTextureSet();
    var resolution = alg.mapexport.textureSetResolution(textureSet);
    // Enable deferred high quality only if resolution > treshold
    if (resolution[0] * resolution[1] <=
        root.linkHQTreshold * root.linkHQTreshold) {
      sendMaps([textureSet]);
    }
    else {
      sendMaps([textureSet], {
        resolution: [
          root.linkDegradedResolution,
          root.linkDegradedResolution * (resolution[1] / resolution[0])
        ]
      });
      hqTimer.start();
    }
  }

  Timer {
    id: lqTimer
    repeat: false
    interval: root.linkQuickInterval
    onTriggered: autoLink()
  }

  Timer {
    id: hqTimer
    repeat: false
    interval: root.linkHQInterval
    onTriggered: sendMaps([getCurrentTextureSet()])
  }

  onComputationStatusChanged: {
    // When the engine status becomes non busy; we send the current texture set.
    // If resolution is too high; we send a first degraded version to
    // quickly visualize results; then we send the high quality version after
    // few seconds.
    // If paint engine status change during this time, we stop all timers.
    lqTimer.stop();
    hqTimer.stop();
    if (root.state === "connected" && !isComputing && enableAutoLink) {
      lqTimer.start();
    }
  }

  function linkToClient(data) {
    root.unityConfig = {
      applicationName: data.applicationName,
      exportPath: data.exportPath.replace("\\", "/"),
      workspacePath: data.workspacePath.replace("\\", "/"),
      linkIdentifier: data.linkIdentifier, // Identifier to allow reconnection
      materials: data.materials, // Materials info (unity path, export preset, shader, association)
      project: data.project // Project configuration (mesh, normal, template, url)
    }

    alg.log.info(root.unityConfig.applicationName + " client connected");
  }

  function applyResourceShaders() {
    var shaderInstances = {
      shaders: {},
      texturesets: {}
    };
    // Create one shader instance per material
    for (var materialName in root.unityConfig.materials) {
      var materialLink = root.unityConfig.materials[materialName];

      var shaderInstanceName = materialName;
      shaderInstances.shaders[shaderInstanceName] = {
        shader: materialLink.resourceShader,
        shaderInstance: shaderInstanceName
      };
      shaderInstances.texturesets[materialName] = {
        shader: shaderInstanceName
      }
    }
    try {
      alg.shaders.shaderInstancesFromObject(shaderInstances);
    }
    catch(err) {
      alg.log.warn("Error while creating shader instances: %1".arg(err.message));
    }
  }

  function initSynchronization(mapsNeeded) {
    // If there is only one material, auto associate Unity one
    // with SP one even if name doesn't match
    {
      var spMaterials = alg.mapexport.documentStructure().materials;
      var unityMaterials = root.unityConfig.materials;
      var unityMaterialsNames = Object.keys(unityMaterials);
      if (spMaterials.length === 1 && unityMaterialsNames.length === 1) {
        var unityMatName = unityMaterialsNames[0];
        var spMatName = spMaterials[0].name;

        var material = root.unityConfig.materials[unityMatName];
        root.unityConfig.materials = {};
        root.unityConfig.materials[spMatName] = material;
      }
    }

    root.state = "connected";
    alg.project.settings.setValue(linkIdentifierKey, root.unityConfig.linkIdentifier);
    if (mapsNeeded) {
      sendMaps();
    }
    applyResourceShaders();
  }

  function createProject(data) {
    linkToClient(data);

    if (alg.project.isOpen()) {
      // TODO: Ask the user if he wants to save its current opened project
      alg.project.close();
    }
    alg.project.create(root.unityConfig.project.meshUrl, null, root.unityConfig.project.template, {
      normalMapFormat: root.unityConfig.project.normal
    });
    alg.project.save(data.project.url);

    // HACK: Painter is not synchronous when creating a project
    setTimeout(initSynchronization, root.initDelayOnProjectCreation);
  }

  function openProject(data) {
    linkToClient(data);

    var projectOpened = alg.project.isOpen();
    var isAlreadyOpen = false;
    try {
      function cleanUrl(url) {
        return alg.fileIO.localFileToUrl(alg.fileIO.urlToLocalFile(url));
      }
      isAlreadyOpen =
        cleanUrl(alg.project.url()) == cleanUrl(data.project.url) ||
        data.linkIdentifier == alg.project.settings.value(linkIdentifierKey);
    }
    catch (err) {}

    // If the project is already opened, keep it
    try {
      if (!isAlreadyOpen) {
        if (projectOpened) {
          // TODO: Ask the user if he wants to save its current opened project
          alg.project.close();
        }
        alg.project.open(data.project.url);
      }
      var mapsNeeded = !isAlreadyOpen;
      initSynchronization(mapsNeeded);
    }
    catch (err) {
      alg.log.exception(err)
      disconnect()
    }
  }

  function sendProjectInfo() {
    try {
      if (alg.project.settings.contains(linkIdentifierKey)) {
        server.sendCommand("OPENED_PROJECT_INFO", {
          linkIdentifier: alg.project.settings.value(linkIdentifierKey),
          projectUrl: alg.project.url()
        });
      }
    }
    catch(err) {}
  }

  CommandServer {
    id: server
    Component.onCompleted: {
      registerCallback("CREATE_PROJECT", createProject);
      registerCallback("OPEN_PROJECT", openProject);
      registerCallback("SEND_PROJECT_INFO", sendProjectInfo);
    }

    onConnectedChanged: {
      if (!connected) {
        disconnect();
      }
    }
  }

  Settings {
    id: settings
  }
}
