/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * ScreenGraph helps you get rid of the navigation boiler plate found in a lot of whole-application UI testing.
 *
 * You create a shared graph of UI 'screens' or 'scenes' for your app, and use it for every test.
 *
 * In your tests, you use a navigator which does the job of getting your tests from place to place in your application,
 * leaving you to concentrate on testing, rather than maintaining brittle and duplicated navigation code.
 * 
 * The shared graph may also have other uses, such as generating screen shots for the App Store or L10n translators.
 *
 * Under the hood, the ScreenGraph is using GameplayKit's path finding to do the heavy lifting.
 */

import Foundation
import GameplayKit
import XCTest

typealias Edge = (XCTestCase, String, UInt) -> ()
typealias SceneBuilder = (ScreenGraphNode) -> ()
typealias NodeVisitor = (String) -> ()

/**
 * ScreenGraph
 * This is the main interface to building a graph of screens/app states and how to navigate between them.
 * The ScreenGraph will be used as a map to navigate the test agent around the app.
 */
public class ScreenGraph {
    let app: XCUIApplication
    var initialSceneName: String?

    var namedScenes: [String: ScreenGraphNode] = [:]
    var nodedScenes: [GKGraphNode: ScreenGraphNode] = [:]

    var isReady: Bool = false

    let gkGraph: GKGraph

    init(_ app: XCUIApplication) {
        self.app = app
        self.gkGraph = GKGraph()
    }
}

extension ScreenGraph {
    /**
     * Method for creating a ScreenGraphNode in the graph. The node should be accompanied by a closure 
     * used to document the exits out of this node to other nodes.
     */
    func createScene(name: String, file: String = #file, line: UInt = #line, builder: (ScreenGraphNode) -> ()) {
        let scene = ScreenGraphNode(map: self, name: name, builder: builder)
        scene.file = file
        scene.line = line
        namedScenes[name] = scene
        nodedScenes[scene.gkNode] = scene
    }
}

extension ScreenGraph {
    /**
     * Create a new navigator object. Navigator objects are the main way of getting around the app.
     * Typically, you'll do this in `TestCase.setUp()`
     */
    func navigator(xcTest: XCTestCase, startingAt: String? = nil, file: String = #file, line: UInt = #line) -> Navigator {
        buildGkGraph()
        var current: ScreenGraphNode?
        if let name = startingAt ?? initialSceneName {
            current = namedScenes[name]
        }

        if current == nil {
            xcTest.recordFailureWithDescription("The app's initial state couldn't be established.",
                inFile: file, atLine: line, expected: false)
        }
        return Navigator(self, xcTest: xcTest, initialScene: current!)
    }

    private func buildGkGraph() {
        if isReady {
            return
        }

        isReady = true

        // Construct all the GKGraphNodes, and add them to the GKGraph.
        let scenes = namedScenes.values
        gkGraph.addNodes(scenes.map { $0.gkNode })

        // Now, use the scene builders to collect edge actions and destinations.
        scenes.forEach { scene in
            scene.builder(scene)
        }

        scenes.forEach { scene in
            let gkNodes = scene.edges.keys.flatMap { self.namedScenes[$0]?.gkNode } as [GKGraphNode]
            scene.gkNode.addConnectionsToNodes(gkNodes, bidirectional: false)
        }
    }
}

typealias Gesture = () -> ()

/**
 * The ScreenGraph is made up of nodes. It is not possible to init these directly, only by creating 
 * screen nodes from the ScreenGraph object.
 * 
 * The ScreenGraphNode has all the methods needed to define edges from this node to another node, using the usual
 * XCUIElement method of moving about.
 */
class ScreenGraphNode {
    let name: String
    private let builder: SceneBuilder
    private let gkNode: GKGraphNode
    private var edges: [String: Edge] = [:]

    private weak var map: ScreenGraph?

    // Iff this node has a backAction, this store temporarily stores 
    // the node we were at before we got to this one. This becomes the node we return to when the backAction is 
    // invoked.
    private weak var returnNode: ScreenGraphNode?

    private var hasBack: Bool {
        return backAction != nil
    }

    /**
     * This is an action that will cause us to go back from where we came from.
     * This is most useful when the same screen is accessible from multiple places, 
     * and we have a back button to return to where we came from.
     */
    var backAction: Gesture?

    /**
     * This flag indicates that once we've moved on from this node, we can't come back to 
     * it via `backAction`. This is especially useful for Menus, and dialogs.
     */
    var dismissOnUse: Bool = false

    var existsWhen: XCUIElement? = nil

    private var line: UInt!

    private var file: String!

    private init(map: ScreenGraph, name: String, builder: SceneBuilder) {
        self.map = map
        self.name = name
        self.gkNode = GKGraphNode()
        self.builder = builder
    }

    private func addEdge(dest: String, by edge: Edge) {
        edges[dest] = edge
        // by this time, we should've added all nodes in to the gkGraph.

        assert(map?.namedScenes[dest] != nil, "Destination scene '\(dest)' has not been created anywhere")
    }
}

private let existsPredicate = NSPredicate(format: "exists == true")
private let enabledPredicate = NSPredicate(format: "enabled == true")
private let hittablePredicate = NSPredicate(format: "hittable == true")
private let noopNodeVisitor: NodeVisitor = { _ in }

extension ScreenGraphNode {
    private func waitForElement(element: XCUIElement, withTest xcTest: XCTestCase, handler: XCWaitCompletionHandler) {
        if element.exists {
            return
        }
        // TODO I'm not satisfied that this is working as expected.
        xcTest.expectationForPredicate(existsPredicate,
                                       evaluatedWithObject: element, handler: nil)
        xcTest.waitForExpectationsWithTimeout(5, handler: handler)
    }
}

// Public methods for defining edges out of this node.
extension ScreenGraphNode {
    /**
     * Declare that by performing the given action/gesture, then we can navigate from this node to the next.
     * 
     * @param withElement – optional, but if provided will attempt to verify it is there before performing the action.
     * @param to – the destination node.
     */
    func gesture(withElement element: XCUIElement? = nil, to nodeName: String, file declFile: String = #file, line declLine: UInt = #line, g: () -> ()) {
        addEdge(nodeName) { xcTest, file, line in
            if let el = element {
                self.waitForElement(el, withTest: xcTest) { _ in
                    xcTest.recordFailureWithDescription("Cannot find \(el)", inFile: declFile, atLine: declLine, expected: false)
                    xcTest.recordFailureWithDescription("Cannot get from \(self.name) to \(nodeName). See \(declFile)", inFile: file, atLine: line, expected: false)
                }
            }
            g()
        }
    }

    func noop(to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(to: nodeName, file: file, line: line) {
            // NOOP.
        }
    }

    /**
     * Declare that by tapping a given element, we should be able to navigate from this node to another.
     *
     * @param element - the element to tap
     * @param to – the destination node.
     */
    func tap(element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            // TODO check if this element is enabled
            element.tap()
        }
    }

    func doubleTap(element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.doubleTap()
        }
    }

    func typeText(text: String, into element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.typeText(text)
        }
    }

    func swipeLeft(element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeLeft()
        }
    }

    func swipeRight(element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeRight()
        }
    }

    func swipeUp(element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeUp()
        }
    }

    func swipeDown(element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeDown()
        }
    }
}

/**
 * The Navigator provides a set of methods to navigate around the app. You can `goto` nodes, `visit` multiple nodes,
 * or visit all nodes, but mostly you just goto. If you take actions that move around the app outside of the
 * navigator, you can re-sync app with navigator my telling it which node it is now at, using the `nowAt` method.
 */
class Navigator {
    private let map: ScreenGraph
    private var currentScene: ScreenGraphNode
    private var returnToRecentScene: ScreenGraphNode
    private let xcTest: XCTestCase

    private init(_ map: ScreenGraph, xcTest: XCTestCase, initialScene: ScreenGraphNode) {
        self.map = map
        self.xcTest = xcTest
        self.currentScene = initialScene
        self.returnToRecentScene = initialScene
    }

    /**
     * Move the application to the named node.
     */
    func goto(nodeName: String, file: String = #file, line: UInt = #line) {
        goto(nodeName, file: file, line: line, visitWith: noopNodeVisitor)
    }

    /**
     * Move the application to the named node, wth an optional node visitor closure, which is called each time the
     * node changes.
     */
    func goto(nodeName: String, file: String = #file, line: UInt = #line, visitWith nodeVisitor: NodeVisitor) {
        let gkSrc = currentScene.gkNode
        guard let gkDest = map.namedScenes[nodeName]?.gkNode else {
            xcTest.recordFailureWithDescription("Cannot route to \(nodeName), because it doesn't exist", inFile: file, atLine: line, expected: false)
            return
        }

        var gkPath = map.gkGraph.findPathFromNode(gkSrc, toNode: gkDest)
        guard gkPath.count > 0 else {
            xcTest.recordFailureWithDescription("Cannot route from \(currentScene.name) to \(nodeName)", inFile: file, atLine: line, expected: false)
            return
        }

        gkPath.removeFirst()
        gkPath.forEach { gkNext in
            if !currentScene.dismissOnUse {
                returnToRecentScene = currentScene
            }

            let nextScene = map.nodedScenes[gkNext]!
            let action = currentScene.edges[nextScene.name]!

            // We definitely have an action, so it's save to unbox.
            action(xcTest, file, line)

            if let testElement = nextScene.existsWhen {
                nextScene.waitForElement(testElement, withTest: xcTest) { _ in
                    // TODO report error in the correct place in the graph.
                    self.xcTest.recordFailureWithDescription("Cannot find \(testElement) in \(nextScene.name)",
                        inFile: nextScene.file,
                        atLine: nextScene.line,
                        expected: false)
                }
            }

            if nextScene.hasBack {
                if nextScene.returnNode == nil {
                    nextScene.returnNode = returnToRecentScene
                    nextScene.gkNode.addConnectionsToNodes([ returnToRecentScene.gkNode ], bidirectional: false)
                    nextScene.gesture(to: returnToRecentScene.name, g: nextScene.backAction!)
                }
            }

            if currentScene.hasBack {
                if nextScene.name == currentScene.returnNode?.name {
                    currentScene.returnNode = nil
                    currentScene.gkNode.removeConnectionsToNodes([ nextScene.gkNode ], bidirectional: false)
                }
            }
            nodeVisitor(currentScene.name)
            currentScene = nextScene
        }
    }

    /**
     * Helper method when the navigator gets out of sync with the actual app.
     * This should not be used too often, as it indicates you should probably have another node in your graph,
     * or you should be using `scene.dismissOnUse = true`.
     * Also useful if you're using XCUIElement taps directly to navigate from one node to another.
     */
    func nowAt(nodeName: String, file: String = #file, line: UInt = #line) {
        guard let newScene = map.namedScenes[nodeName] else {
            xcTest.recordFailureWithDescription("Cannot force to unknown \(nodeName). Currently at \(currentScene.name)", inFile: file, atLine: line, expected: false)
            return
        }
        currentScene = newScene
    }

    /**
     * Visit the named nodes, calling the NodeVisitor the first time it is encountered.
     */
    func visitNodes(nodes: [String], file: String = #file, line: UInt = #line, f: NodeVisitor) {
        var visitedNodes = Set<String>()
        let desiredNodes = Set<String>(nodes)
        nodes.forEach { node in
            if visitedNodes.contains(node) {
                return
            }
            self.goto(node, file: file, line: line) { visitedNode in
                if desiredNodes.contains(visitedNode) && !visitedNodes.contains(visitedNode) {
                    f(visitedNode)
                }
                visitedNodes.insert(visitedNode)
            }
        }
    }

    /**
     * Visit all nodes, calling the NodeVisitor the first time it is encountered.
     * 
     * Some nodes may not be immediately available, depending on the state of the app.
     */
    func visitAll(file: String = #file, line: UInt = #line, f: NodeVisitor) {
        let nodes: [String] = self.map.namedScenes.keys.map { $0 } // keys can't be coerced into a [String]
        self.visitNodes(nodes, file: file, line: line, f: f)
    }

    /**
     * Move the app back to its initial state.
     * This may not be possible.
     */
    func revert(file: String = #file, line: UInt = #line) {
        if let initial = self.map.initialSceneName {
            self.goto(initial, file: file, line: line)
        }
    }
}
