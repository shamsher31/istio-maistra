// Copyright Istio Authors
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

package controller

import (
	"fmt"
	"time"

	xnsinformers "github.com/maistra/xns-informer/pkg/informers"
	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	corev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	listerv1 "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"

	"istio.io/istio/pkg/kube"
	"istio.io/istio/pkg/queue"
	"istio.io/istio/security/pkg/k8s"
	"istio.io/pkg/log"
)

const (
	// Every NamespaceResyncPeriod, namespaceUpdated() will be invoked
	// for every namespace. This value must be configured so Citadel
	// can update its CA certificate in a ConfigMap in every namespace.
	NamespaceResyncPeriod = time.Second * 60
	// The name of the ConfigMap in each namespace storing the root cert of non-Kube CA.
	CACertNamespaceConfigMap = "istio-ca-root-cert"
)

var (
	configMapLabel = map[string]string{"istio.io/config": "true"}
)

// NamespaceController manages reconciles a configmap in each namespace with a desired set of data.
type NamespaceController struct {
	// getData is the function to fetch the data we will insert into the config map
	getData func() map[string]string
	client  corev1.CoreV1Interface

	queue              queue.Instance
	namespacesInformer cache.SharedInformer
	configMapInformer  cache.SharedInformer
	namespaceLister    listerv1.NamespaceLister
	configmapLister    listerv1.ConfigMapLister

	usesMemberRollController bool
	namespaces               xnsinformers.NamespaceSet
}

// NewNamespaceController returns a pointer to a newly constructed NamespaceController instance.
func NewNamespaceController(data func() map[string]string, kubeClient kube.Client) *NamespaceController {
	c := &NamespaceController{
		getData: data,
		client:  kubeClient.CoreV1(),
		queue:   queue.NewQueue(time.Second),
	}

	c.configMapInformer = kubeClient.KubeInformer().Core().V1().ConfigMaps().Informer()
	c.configmapLister = kubeClient.KubeInformer().Core().V1().ConfigMaps().Lister()

	c.configMapInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		UpdateFunc: func(_, obj interface{}) {
			cm, err := convertToConfigMap(obj)
			if err != nil {
				log.Errorf("failed to convert to configmap: %v", err)
			}
			// This is a change to a configmap we don't watch, ignore it
			if cm.Name != CACertNamespaceConfigMap {
				return
			}
			c.queue.Push(func() error {
				return c.configMapChange(cm)
			})
		},
		DeleteFunc: func(obj interface{}) {
			cm, err := convertToConfigMap(obj)
			if err != nil {
				log.Errorf("failed to convert to configmap: %v", err)
			}
			// This is a change to a configmap we don't watch, ignore it
			if cm.Name != CACertNamespaceConfigMap {
				return
			}

			c.queue.Push(func() error {
				// If a MemberRoll controller is in use, and the set of
				// namespaces still includes the one for this ConfigMap,
				// then recreate the ConfigMap, otherwise do nothing.
				if c.usesMemberRollController {
					if c.namespaces.Contains(cm.Namespace) {
						return c.insertDataForNamespace(cm.Namespace)
					}

					return nil
				}

				ns, err := c.namespaceLister.Get(cm.Namespace)
				if err != nil {
					// namespace is deleted before
					if apierrors.IsNotFound(err) {
						return nil
					}
					return err
				}
				// If the namespace is terminating, we may get into a loop of trying to re-add the configmap back
				// We should make sure the namespace still exists
				if ns.Status.Phase != v1.NamespaceTerminating {
					return c.insertDataForNamespace(cm.Namespace)
				}
				return nil
			})
		},
	})

	// If a MemberRoll controller is configured on the client, skip creating the
	// namespace informer and just respond to changes in the MemberRoll.
	if mrc := kubeClient.GetMemberRoll(); mrc != nil {
		c.usesMemberRollController = true
		c.namespaces = xnsinformers.NewNamespaceSet()
		c.namespaces.AddHandler(xnsinformers.NamespaceSetHandlerFuncs{
			AddFunc: func(ns string) {
				if err := c.insertDataForNamespace(ns); err != nil {
					log.Errorf("error inserting data for namespace: %v", err)
				}
			},
		})

		mrc.Register(c.namespaces, "namespace-controller")
		return c
	}

	c.namespaceLister = kubeClient.KubeInformer().Core().V1().Namespaces().Lister()
	c.namespacesInformer = kubeClient.KubeInformer().Core().V1().Namespaces().Informer()
	c.namespacesInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			c.queue.Push(func() error {
				return c.namespaceChange(obj.(*v1.Namespace))
			})
		},
		UpdateFunc: func(_, obj interface{}) {
			c.queue.Push(func() error {
				return c.namespaceChange(obj.(*v1.Namespace))
			})
		},
	})

	return c
}

// Run starts the NamespaceController until a value is sent to stopCh.
func (nc *NamespaceController) Run(stopCh <-chan struct{}) {
	syncFuncs := []cache.InformerSynced{nc.configMapInformer.HasSynced}

	if nc.namespacesInformer != nil {
		syncFuncs = append(syncFuncs, nc.namespacesInformer.HasSynced)
	}

	cache.WaitForCacheSync(stopCh, syncFuncs...)
	log.Infof("Namespace controller started")
	go nc.queue.Run(stopCh)
}

// insertDataForNamespace will add data into the configmap for the specified namespace
// If the configmap is not found, it will be created.
// If you know the current contents of the configmap, using UpdateDataInConfigMap is more efficient.
func (nc *NamespaceController) insertDataForNamespace(ns string) error {
	meta := metav1.ObjectMeta{
		Name:      CACertNamespaceConfigMap,
		Namespace: ns,
		Labels:    configMapLabel,
	}
	return k8s.InsertDataToConfigMap(nc.client, nc.configmapLister, meta, nc.getData())
}

// On namespace change, update the config map.
// If terminating, this will be skipped
func (nc *NamespaceController) namespaceChange(ns *v1.Namespace) error {
	if ns.Status.Phase != v1.NamespaceTerminating {
		return nc.insertDataForNamespace(ns.Name)
	}
	return nil
}

// When a config map is changed, merge the data into the configmap
func (nc *NamespaceController) configMapChange(cm *v1.ConfigMap) error {
	if err := k8s.UpdateDataInConfigMap(nc.client, cm.DeepCopy(), nc.getData()); err != nil {
		return fmt.Errorf("error when inserting CA cert to configmap %v: %v", cm.Name, err)
	}
	return nil
}

func convertToConfigMap(obj interface{}) (*v1.ConfigMap, error) {
	cm, ok := obj.(*v1.ConfigMap)
	if !ok {
		tombstone, ok := obj.(cache.DeletedFinalStateUnknown)
		if !ok {
			return nil, fmt.Errorf("couldn't get object from tombstone %#v", obj)
		}
		cm, ok = tombstone.Obj.(*v1.ConfigMap)
		if !ok {
			return nil, fmt.Errorf("tombstone contained object that is not a ConfigMap %#v", obj)
		}
	}
	return cm, nil
}
