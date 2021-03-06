// Copyright (c) 2018 SAP SE or an SAP affiliate company. All rights reserved. This file is licensed under the Apache Software License, v. 2 except as noted otherwise in the LICENSE file.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package cmd

import (
	"fmt"
	"path"

	"github.com/coreos/etcd/pkg/types"
	"github.com/gardener/etcd-backup-restore/pkg/initializer"
	"github.com/gardener/etcd-backup-restore/pkg/snapshot/restorer"
	"github.com/gardener/etcd-backup-restore/pkg/snapstore"
	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

// NewInitializeCommand returns the command to initialize etcd by validating the data
// directory and restoring from cloud store if needed.
func NewInitializeCommand(stopCh <-chan struct{}) *cobra.Command {

	// restoreCmd represents the restore command
	initializeCmd := &cobra.Command{
		Use:   "initialize",
		Short: "initialize an etcd instance.",
		Long:  fmt.Sprintf(`Initializes an etcd instance. Data directory is checked for corruption and restored in case of corruption.`),
		Run: func(cmd *cobra.Command, args []string) {
			logger := logrus.New()

			clusterUrlsMap, err := types.NewURLsMap(restoreCluster)
			if err != nil {
				logger.Fatalf("failed creating url map for restore cluster: %v", err)
			}

			peerUrls, err := types.NewURLs(restorePeerURLs)
			if err != nil {
				logger.Fatalf("failed parsing peers urls for restore cluster: %v", err)
			}

			options := &restorer.RestoreOptions{
				RestoreDataDir: restoreDataDir,
				Name:           restoreName,
				ClusterURLs:    clusterUrlsMap,
				PeerURLs:       peerUrls,
				ClusterToken:   restoreClusterToken,
				SkipHashCheck:  skipHashCheck,
				MaxFetchers:    restoreMaxFetchers,
			}

			var snapstoreConfig *snapstore.Config
			if storageProvider != "" {
				snapstoreConfig = &snapstore.Config{
					Provider:                storageProvider,
					Container:               storageContainer,
					Prefix:                  path.Join(storagePrefix, backupFormatVersion),
					MaxParallelChunkUploads: maxParallelChunkUploads,
					TempDir:                 snapstoreTempDir,
				}
			}
			etcdInitializer := initializer.NewInitializer(options, snapstoreConfig, logger)
			err = etcdInitializer.Initialize()
			if err != nil {
				logger.Fatalf("initializer failed. %v", err)
			}
		},
	}
	initializeEtcdFlags(initializeCmd)
	initializeSnapstoreFlags(initializeCmd)
	return initializeCmd
}
