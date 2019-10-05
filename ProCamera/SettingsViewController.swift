//
//  SettingsViewController.swift
//  ProCamera
//
//  Created by Hao Wang on 3/8/15.
//  Copyright (c) 2015 Hao Wang. All rights reserved.
//

import UIKit


class SettingsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, settingsDelegate {
    
    private let settings = [
        "Grid",
        "Geo Tagging",
        "Lossless Quality"
    ]
    var settingsValue: [String: Bool] = [String: Bool]()
    
    @IBOutlet weak var tableView: UITableView!
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }
    
    override var shouldAutorotate: Bool {
        return true
    }
    
    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        self.view.window?.reloadInputViews()
    }
            
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        let settingsValueTmp = UserDefaults.standard.object(forKey: "settingsStore") as? [String: Bool]
        if settingsValueTmp != nil {
            settingsValue = settingsValueTmp!
        } else {
            settingsValue = [String: Bool]()
        }
        view.backgroundColor = .white
        tableView.backgroundColor = .white
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    deinit {
        print("deinit")
    }
    
    @IBAction func onClose(_ sender: UIButton) {
        dismiss(animated: true, completion: {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "settingsUpdatedNotification"), object: nil, userInfo: self.settingsValue)
        })
    }
    
    func changeSetting(name: String, value: Bool) {
        switch name {
        case settings[0], settings[1], settings[2]:
            settingsValue[name] = value
        default: break
        }
        //set data
        UserDefaults.standard.set(settingsValue, forKey: "settingsStore")
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row < 4 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "settingBoolCell") as! SettingBoolTableViewCell
            var on: Bool? = self.settingsValue[settings[indexPath.row]]
            if on == nil {
                on = false
            }
            cell.switchBtn.setOn(on!, animated: true)
            cell.settingName.text = settings[indexPath.row]
            cell.delegate = self
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "settingOptionsCell") as! SettingOptionsTableViewCell
            cell.settingName.text = settings[indexPath.row]
            cell.optionVal.text = "Default" //place holder
            return cell
        }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return settings.count
    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

}
